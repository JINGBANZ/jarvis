# Harbor Ledger preparation

Harbor Ledger is a fictional receipt-processing project used for an interview practice session.
Each merchant supplies a receipt identifier and amount. Repeated receipt delivery is expected after
network interruption. The interview design stores a replay key and the accepted outcome atomically;
the same key returns the original outcome. A different amount with that key waits for review.
Do not treat acceptance as evidence that a downstream charge completed. The candidate should explain
the decision in a short connected answer before discussing storage expiry or recovery after restart.
