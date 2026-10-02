enum CustomRuleDeletionResult: Equatable, Sendable {
  enum Failure: Equatable, Sendable { case busy, incompleteCollection, staleConfirmation }
  case unavailable(Failure)
  case committed(CustomRuleUpdateOutcome)
}
