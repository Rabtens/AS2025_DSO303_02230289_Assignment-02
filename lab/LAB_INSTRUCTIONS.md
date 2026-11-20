# Cloud Architecture Lab

1. Open the Cloud Architecture Lab and import the [saved architecture](../evidence/Online%20Exam%20Platform%20-%20Production%20Architecture%20%282%20AZ%29.json). It contains 46 nodes and 52 connections.
2. Check the two Availability Zones. Each has a public NAT subnet, a private Lambda app subnet, and a private database subnet. Check the edge, authentication, storage, queue, and monitoring components against the [production diagram](../architecture/architecture.md).
3. Simulate the exam flow. Trace sign-in through Cognito, the exam request through CloudFront and API Gateway to Lambda, and the 30-second autosave write through RDS Proxy to Aurora. Compare the trace with the [exam screenshot](../evidence/lab-walkthrough-1.png).
4. Simulate a 40 MB submission. Trace the presign request to the API, the direct upload to S3, and the S3 event through SQS to the notifier Lambda and SES. Compare the result with the [upload screenshot](../evidence/lab-walkthrough-2.png).
5. Simulate loss of the writer's AZ. Trace write recovery through the surviving AZ and the Aurora reader's promotion, then clear the simulated failure. Compare with the [AZ-loss screenshot](../evidence/lab-az-failure.png).

The lab models the production topology. The AWS Free Plan deployment uses a single Aurora Express writer, so the lab failover screenshot is evidence of simulated behavior.
