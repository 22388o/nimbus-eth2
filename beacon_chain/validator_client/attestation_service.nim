import std/[sets, sequtils]
import chronicles
import common, api, block_service

logScope: service = "attestation_service"

type
  AggregateItem* = object
    aggregator_index: uint64
    selection_proof: ValidatorSig
    validator: AttachedValidator

proc serveAttestation(service: AttestationServiceRef, adata: AttestationData,
                      duty: DutyAndProof): Future[bool] {.async.} =
  let vc = service.client
  let validator = vc.attachedValidators.getValidator(duty.data.pubkey)
  if validator.index.isNone():
    warn "Validator index is missing", validator = validator.pubKey
    return false

  let fork = vc.fork.get()

  # TODO: signing_root is recomputed in signBlockProposal just after,
  # but not for locally attached validators.
  let signingRoot =
    compute_attestation_root(fork, vc.beaconGenesis.genesis_validators_root,
                             adata)

  let vindex = validator.index.get()
  let notSlashable = vc.attachedValidators.slashingProtection
                       .registerAttestation(vindex, validator.pubKey,
                                            adata.source.epoch,
                                            adata.target.epoch, signingRoot)
  if notSlashable.isErr():
    warn "Slashing protection activated for attestation", slot = duty.data.slot,
         validator = validator.pubKey,
         validator_index = duty.data.validator_index,
         badVoteDetails = $notSlashable.error
    return false

  let attestation = await validator.produceAndSignAttestation(adata,
    int(duty.data.committee_length),
    Natural(duty.data.validator_committee_index),
    fork, vc.beaconGenesis.genesis_validators_root)

  let res =
    try:
      await vc.submitPoolAttestations(@[attestation])
    except ValidatorApiError as exc:
      error "Unable to submit attestation", slot = duty.data.slot,
        validator = validator.pubKey,
        validator_index = duty.data.validator_index
      raise exc

  let delay = vc.getDelay(seconds(int64(SECONDS_PER_SLOT) div 3))
  if res:
    notice "Attestation published", validator = validator.pubKey,
           validator_index = duty.data.validator_index, slot = duty.data.slot,
           delay = delay
    return true
  else:
    warn "Attestation was not accepted by beacon node",
         validator = validator.pubKey,
         validator_index = duty.data.validator_index,
         slot = duty.data.slot, delay = delay
    return false

proc serveAggregateAndProof*(service: AttestationServiceRef,
                             proof: AggregateAndProof,
                             validator: AttachedValidator): Future[bool] {.
     async.} =
  let
    vc = service.client
    genesisRoot = vc.beaconGenesis.genesis_validators_root
    fork = vc.fork.get()

  let signature = await signAggregateAndProof(validator, proof, fork,
                                              genesisRoot)
  let signedProof = SignedAggregateAndProof(message: proof,
                                            signature: signature)
  try:
    return await vc.publishAggregateAndProofs(@[signedProof]):
  except ValidatorApiError:
    warn "Unable to publish aggregate and proofs"
    return false
  except CatchableError as exc:
    error "Unexpected error happened", err_name = exc.name,
          err_msg = exc.msg
    return false

proc produceAndPublishAttestations*(service: AttestationServiceRef,
                                    slot: Slot, committee_index: CommitteeIndex,
                                    duties: seq[DutyAndProof]
                                   ): Future[AttestationData] {.
     async.} =
  doAssert(MAX_VALIDATORS_PER_COMMITTEE <= uint64(high(int)))
  let vc = service.client

  # This call could raise ValidatorApiError, but it is handled in
  # publishAttestationsAndAggregates().
  let ad = await vc.produceAttestationData(slot, committee_index)

  let pendingAttestations =
    block:
      var res: seq[Future[bool]]
      for duty in duties:
        debug "Serving attestation duty", duty = duty.data, epoch = slot.epoch()
        if (duty.data.slot != ad.slot) or
           (uint64(duty.data.committee_index) != ad.index):
          error "Inconsistent validator duties during attestation signing",
                validator = duty.data.pubkey, duty_slot = duty.data.slot,
                duty_index = duty.data.committee_index,
                attestation_slot = ad.slot, attestation_index = ad.index
          continue
        res.add(service.serveAttestation(ad, duty))
      res

  let statistics =
    block:
      var errored, succeed, failed = 0
      try:
        await allFutures(pendingAttestations)
      except CancelledError:
        for fut in pendingAttestations:
          if not(fut.finished()):
            fut.cancel()
        await allFutures(pendingAttestations)

      for future in pendingAttestations:
        if future.done():
          if future.read():
            inc(succeed)
          else:
            inc(failed)
        else:
          inc(errored)
      (succeed, errored, failed)

  let delay = vc.getDelay(seconds(int64(SECONDS_PER_SLOT) div 3))
  debug "Attestation statistics", total = len(pendingAttestations),
         succeed = statistics[0], failed_to_deliver = statistics[1],
         not_accepted = statistics[2], delay = delay, slot = slot,
         committee_index = committeeIndex, duties_count = len(duties)

  return ad

proc produceAndPublishAggregates(service: AttestationServiceRef,
                                 adata: AttestationData,
                                 duties: seq[DutyAndProof]) {.async.} =
  let
    vc = service.client
    slot = adata.slot
    committeeIndex = CommitteeIndex(adata.index)
    attestationRoot = adata.hash_tree_root()
    genesisRoot = vc.beaconGenesis.genesis_validators_root

  let aggregateItems =
    block:
      var res: seq[AggregateItem]
      for duty in duties:
        let validator = vc.attachedValidators.getValidator(duty.data.pubkey)
        if not(isNil(validator)):
          if (duty.data.slot != slot) or
             (duty.data.committee_index != committeeIndex):
            error "Inconsistent validator duties during aggregate signing",
                  duty_slot = duty.data.slot, slot = slot,
                  duty_committee_index = duty.data.committee_index,
                  committee_index = committeeIndex
            continue
          if duty.slotSig.isSome():
            let slotSignature = duty.slotSig.get()
            if is_aggregator(duty.data.committee_length, slotSignature):
              res.add(AggregateItem(
                aggregator_index: uint64(duty.data.validator_index),
                selection_proof: slotSignature,
                validator: validator
              ))
      res

  if len(aggregateItems) > 0:
    let aggAttestation =
      try:
        await vc.getAggregatedAttestation(slot, attestationRoot)
      except ValidatorApiError:
        error "Unable to retrieve aggregated attestation data"
        return

    let pendingAggregates =
      block:
        var res: seq[Future[bool]]
        for item in aggregateItems:
          let proof = AggregateAndProof(
            aggregator_index: item.aggregator_index,
            aggregate: aggAttestation,
            selection_proof: item.selection_proof
          )
          res.add(service.serveAggregateAndProof(proof, item.validator))
        res

    let statistics =
      block:
        var errored, succeed, failed = 0
        try:
          await allFutures(pendingAggregates)
        except CancelledError:
          for fut in pendingAggregates:
            if not(fut.finished()):
              fut.cancel()
          await allFutures(pendingAggregates)

        for future in pendingAggregates:
          if future.done():
            if future.read():
              inc(succeed)
            else:
              inc(failed)
          else:
            inc(errored)
        (succeed, errored, failed)

    let delay = vc.getDelay(seconds((int64(SECONDS_PER_SLOT) div 3) * 2))
    debug "Aggregate attestation statistics", total = len(pendingAggregates),
       succeed = statistics[0], failed_to_deliver = statistics[1],
       not_accepted = statistics[2], delay = delay, slot = slot,
       committee_index = committeeIndex

  else:
    notice "No aggregate and proofs scheduled for slot", slot = slot,
           committee_index = committeeIndex

proc publishAttestationsAndAggregates(service: AttestationServiceRef,
                                      slot: Slot,
                                      committee_index: CommitteeIndex,
                                      duties: seq[DutyAndProof]) {.async.} =
  let vc = service.client
  let aggregateTime =
    # chronos.Duration substraction could not return negative value, in such
    # case it will return `ZeroDuration`.
    vc.beaconClock.durationToNextSlot() - seconds(int64(SECONDS_PER_SLOT) div 3)

  # Waiting for blocks to be published before attesting.
  # TODO (cheatfate): Here should be present timeout.
  let startTime = Moment.now()
  await vc.waitForBlockPublished(slot)
  let finishTime = Moment.now()
  debug "Block proposal awaited", slot = slot,
                                  duration = (finishTime - startTime)

  block:
    let delay = vc.getDelay(seconds(int64(SECONDS_PER_SLOT) div 3))
    notice "Producing attestations", delay = delay, slot = slot,
                                     committee_index = committee_index,
                                     duties_count = len(duties)

  let ad =
    try:
      await service.produceAndPublishAttestations(slot, committee_index,
                                                  duties)
    except ValidatorApiError:
      error "Unable to proceed attestations"
      return

  if aggregateTime != ZeroDuration:
    await sleepAsync(aggregateTime)

  block:
    let delay = vc.getDelay(seconds((int64(SECONDS_PER_SLOT) div 3) * 2))
    notice "Producing aggregate and proofs", delay = delay
  await service.produceAndPublishAggregates(ad, duties)

proc spawnAttestationTasks(service: AttestationServiceRef,
                           slot: Slot) =
  let vc = service.client
  let dutiesByCommittee =
    block:
      var res: Table[CommitteeIndex, seq[DutyAndProof]]
      let attesters = vc.getAttesterDutiesForSlot(slot)
      var default: seq[DutyAndProof]
      for item in attesters:
        res.mgetOrPut(item.data.committee_index, default).add(item)
      res
  for index, duties in dutiesByCommittee.pairs():
    if len(duties) > 0:
      asyncSpawn service.publishAttestationsAndAggregates(slot, index, duties)

proc mainLoop(service: AttestationServiceRef) {.async.} =
  let vc = service.client
  service.state = ServiceState.Running
  try:
    while true:
      let sleepTime = vc.beaconClock.durationToNextSlot() +
                        seconds(int64(SECONDS_PER_SLOT) div 3)
      let sres = vc.getCurrentSlot()
      if sres.isSome():
        let currentSlot = sres.get()
        service.spawnAttestationTasks(currentSlot)
      await sleepAsync(sleepTime)
  except CatchableError as exc:
    warn "Service crashed with unexpected error", err_name = exc.name,
         err_msg = exc.msg

proc init*(t: typedesc[AttestationServiceRef],
           vc: ValidatorClientRef): Future[AttestationServiceRef] {.async.} =
  debug "Initializing service"
  var res = AttestationServiceRef(client: vc, state: ServiceState.Initialized)
  return res

proc start*(service: AttestationServiceRef) =
  service.lifeFut = mainLoop(service)