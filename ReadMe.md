# GitHub Projects (V2) Scheduled Processing #

This repository provides an AWS Lambda to move a GitHub Projects (V2) item to another status at a previously scheduled date.

This is simply a scheduling companion to [the corresponding webhook receiver](https://github.com/MPLew-is/github-projects-webhook-receiver), and so the setup below assumes you have already fully followed that project's setup instructions.

**Important**: this is still in extremely early development, and the below setup steps are mostly to document my own deployment of this Lambda rather than be a guarantee of how to set this up from scratch.


## Setup ##

1. Build the Lambda in a container, and copy the resulting Zip to your host: `DOCKER_BUILDKIT=1 docker build --output .lambda`
2. [Create an AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html) and upload the Zip file at `.lambda/debug/GithubProjectsScheduledProcessing.zip` as the deployment package
	- You will need to [grant the Lambda permissions](https://docs.aws.amazon.com/lambda/latest/dg/lambda-permissions.html) to the Secrets (`githubCredentials` and `webhookReceiverConfiguration`) and DynamoDB table created for the other Lambda
3. [Set environment variables for the Lambda](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html) to function correctly:
	- `REGION`: AWS region name in which you've deployed the Lambda and secrets (for example, `us-west-1`)
	- `GITHUB_CREDENTIALS_SECRET_ARN`: ARN for the GitHub credentials secret created for the other Lambda
	- `CONFIGURATION_SECRET_ARN`: ARN for the configuration secret created for the other Lambda
	- `SCHEDULED_MOVES_TABLE_NAME`: name of the DynamoDB table created for the other Lambda
	- `SCHEDULED_MOVES_DATE_INDEX_NAME`: name of the DynamoDB global secondary index created for the other Lambda
4. [Create a Cloudwatch Event Rule to invoke your Lambda](https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html)
