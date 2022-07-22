import Foundation

import Algorithms
import AsyncHTTPClient
import AWSDynamoDB
import AWSLambdaRuntime
import AWSSecretsManager
import DeepCodable
import GithubApiClient


/// Failure scenarios during the Lambda's initialization before event processing
enum LambdaInitializationError: Error, CustomStringConvertible {
	/**
	A required environment variable was not set

	This case has the name of the missing environment variable attached to it for debugging purposes.
	*/
	case environmentVariableNotFound(variable: String)
	/**
	A required AWS Secrets Manager secret had no value

	This case has a human-friendly description and ARN for the secret attached to it for debugging purposes.
	*/
	case secretNil(description: String, arn: String)
	/**
	A required AWS Secrets Manager secret could not be decoded from UTF-8

	This case has a human-friendly description and ARN for the secret attached to it for debugging purposes.
	*/
	case secretNotUtf8(description: String, arn: String)

	var description: String {
		switch self {
			case .environmentVariableNotFound(let variable):
				return "Environment variable not found: \(variable)"

			case .secretNil(let name, let arn):
				return "AWS Secrets Manager Secret for value '\(name)' returned an empty value, tried to access ARN: \(arn)"

			case .secretNotUtf8(let name, let arn):
				return "AWS Secrets Manager Secret for value '\(name)' could not be decoded as UTF-8, tried to access ARN: \(arn)"
		}
	}
}


/// Required GitHub credentials, to be decoded from an AWS Secrets Manager response
struct GithubCredentials: Decodable {
	/// GitHub App ID that is being used to authenticate to the GitHub API
	let appId: String
	/// PEM-encoded GitHub App private key, to sign authentication tokens for API access
	let privateKey: String
}

/// Required Lambda configuration, to be decoded from an AWS Secrets Manager response
struct Configuration: Decodable {
	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String
}


/// Shortcut alias for a Dynamo DB attribute value, for convenience
typealias DynamoDbValue = DynamoDbClientTypes.AttributeValue


@main
final class FunctionUrlLambdaHandler: LambdaHandler {
	/// Stored AWS DynamoDB client
	let dynamoDbClient: DynamoDbClient

	/// Stored client for interfacing with the GitHub API
	let githubClient: GithubApiClient

	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String


	init(context: LambdaInitializationContext) async throws {
		context.logger.info("Creating AWS service clients")
		guard let region = Lambda.env("REGION") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "REGION")
		}
		self.dynamoDbClient = try .init(region: region)
		let secretsManagerClient = try SecretsManagerClient(region: region)


		// Use a single decoder for all the decoding below, for performance.
		let decoder: JSONDecoder = .init()


		/*
		Fetch and decode the values of required secrets, from ARNs provided via environment variables.
		These seem to have to be sequential to avoid segfaults, but could in theory be transformed into `async let` statements to exploit concurrency.
		*/
		context.logger.info("Fetching GitHub Credentials")
		guard let githubCredentials_secretArn = Lambda.env("GITHUB_CREDENTIALS_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "GITHUB_CREDENTIALS_SECRET_ARN")
		}
		let githubCredentials_secretRequest: GetSecretValueInput = .init(secretId: githubCredentials_secretArn)
		let githubCredentials_secretResponse = try await secretsManagerClient.getSecretValue(input: githubCredentials_secretRequest)

		context.logger.info("Decoding GitHub Credentials")
		guard let githubCredentials_string = githubCredentials_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		guard let githubCredentials_data = githubCredentials_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		let githubCredentials = try decoder.decode(GithubCredentials.self, from: githubCredentials_data)

		context.logger.info("Creating underlying GitHub client")
		self.githubClient = try .init(
			appId: githubCredentials.appId,
			privateKey: githubCredentials.privateKey
		)


		context.logger.info("Fetching Lambda configuration")
		guard let configuration_secretArn = Lambda.env("CONFIGURATION_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "CONFIGURATION_SECRET_ARN")
		}
		let configuration_secretRequest: GetSecretValueInput = .init(secretId: configuration_secretArn)
		let configuration_secretResponse = try await secretsManagerClient.getSecretValue(input: configuration_secretRequest)

		context.logger.info("Decoding Lambda configuration")
		guard let configuration_string = configuration_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Lambda configuration", arn: configuration_secretArn)
		}
		guard let configuration_data = configuration_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Lambda configuration", arn: configuration_secretArn)
		}
		let configuration = try decoder.decode(Configuration.self, from: configuration_data)

		self.githubProjectId = configuration.githubProjectId
	}


	/// A completely empty object, since we don't care about any input or output from this Lambda
	struct Empty: Codable {}

	typealias Event  = Empty
	typealias Output = Empty


	/// GitHub GraphQL mutation of a project V2 item field value, containing both the query text and its variables
	struct GraphqlUpdateProjectItemMutation: Encodable {
		/// Static query used to execute the mutation with the variables on an instance
		static let query = """
			mutation($input: UpdateProjectV2ItemFieldValueInput!) {
				updateProjectV2ItemFieldValue(input: $input) {
					clientMutationId
				}
			}
			"""

		/// Input values for [an `updateProjectV2ItemFieldValue` mutation](https://docs.github.com/en/graphql/reference/input-objects#updateprojectv2itemfieldvalueinput)
		struct UpdateProjectV2ItemFieldValueInput: DeepEncodable {
			static let codingTree = CodingTree {
				Key("projectId", containing: \.projectId)
				Key("itemId", containing: \.itemId)
				Key("fieldId", containing: \.fieldId)

				Key("value") {
					Key("singleSelectOptionId", containing: \.fieldValue)
				}
			}

			let projectId: String
			let itemId: String
			let fieldId: String
			let fieldValue: String
		}

		// GraphQL is fine decoding complex structures, so make our `query` above a little simpler with another nested level
		let input: UpdateProjectV2ItemFieldValueInput
	}

	func handle(_: Event, context: LambdaContext) async throws -> Output {
		guard let scheduledMovesTableName = Lambda.env("SCHEDULED_MOVES_TABLE_NAME") else {
			context.logger.critical("No DynamoDB table name found for scheduled moves table from environment variable: SCHEDULED_MOVES_TABLE_NAME")
			return .init()
		}

		guard let scheduledMovesIndexName = Lambda.env("SCHEDULED_MOVES_DATE_INDEX_NAME") else {
			context.logger.critical("No DynamoDB index name found for scheduled moves table from environment variable: SCHEDULED_MOVES_DATE_INDEX_NAME")
			return .init()
		}


		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd"
		let now_string = dateFormatter.string(from: Date())


		let keyConditionExpression = "projectId = :project AND scheduledDate <= :today"
		let expressionAttributeValues: [String: DynamoDbValue] = [
			":project": .s(self.githubProjectId),
			":today"  : .s(now_string),
		]
		context.logger.info("Querying DynamoDB on the following index specifier: \(scheduledMovesTableName)/\(scheduledMovesIndexName)")
		let response = try await self.dynamoDbClient.query(
			input: .init(
				expressionAttributeValues: expressionAttributeValues,
				indexName: scheduledMovesIndexName,
				keyConditionExpression: keyConditionExpression,
				tableName: scheduledMovesTableName
			)
		)


		guard let items = response.items else {
			context.logger.error("Query items returned `nil` (not empty)")
			return .init()
		}

		context.logger.info("Received items from DynamoDB query with count: \(items.count)")


		/// Item IDs that have had their status changes processed and are ready for cleanup
		var processedItemIds: [String] = []
		for item in items {
			guard case .s(let itemId) = item["itemId"] else {
				context.logger.error("No value for required attribute 'itemId' (this should be impossible, it's the partition key)")
				continue
			}

			guard case .s(let projectId) = item["projectId"] else {
				context.logger.error("No value for required attribute 'projectId' on item: \(itemId)")
				continue
			}
			guard case .s(let fieldId) = item["fieldId"] else {
				context.logger.error("No value for required attribute 'fieldId' on item: \(itemId)")
				continue
			}
			guard case .s(let fieldValue) = item["fieldValue"] else {
				context.logger.error("No value for required attribute 'fieldValue' on item: \(itemId)")
				continue
			}
			guard case .s(let fieldValueName) = item["fieldValueName"] else {
				context.logger.error("No value for required attribute 'fieldValueName' on item: \(itemId)")
				continue
			}

			guard case .n(let installationId_string) = item["installationId"] else {
				context.logger.error("No value for required attribute 'installationId' on item: \(itemId)")
				continue
			}

			guard case .s(let commentsUrl) = item["commentsUrl"] else {
				context.logger.error("No value for required attribute 'commentsUrl' on item: \(itemId)")
				continue
			}
			guard case .s(let username) = item["username"] else {
				context.logger.error("No value for required attribute 'username' on item: \(itemId)")
				continue
			}

			guard let installationId = Int(installationId_string) else {
				context.logger.error("Installation ID string could not be converted to integer: \(installationId_string)")
				continue
			}

			context.logger.info("Processing item: \(itemId)")

			let mutationVariables = GraphqlUpdateProjectItemMutation(
				input: .init(
					projectId: projectId,
					itemId: itemId,
					fieldId: fieldId,
					fieldValue: fieldValue
				)
			)
			let mutationVariables_data = try JSONEncoder().encode(mutationVariables)
			guard let mutationVariables_string = String(data: mutationVariables_data, encoding: .utf8) else {
				context.logger.error("Could not encode mutation variables to string for item: \(itemId)")
				continue
			}

			let mutationRequestBody = GraphqlRequest(
				query: type(of: mutationVariables).query,
				variables: mutationVariables_string
			)
			let _ = try await self.githubClient.graphqlQuery(mutationRequestBody, for: installationId)

			let _ = try await self.githubClient.createIssueComment(
				url: commentsUrl,
				body: """
					@\(username) this item has been moved to status `\(fieldValueName)`
					""",
				for: installationId
			)

			processedItemIds.append(itemId)
			context.logger.info("Successfully processed item: \(itemId)")
		}


		context.logger.info("Successfully processed all items with count: \(processedItemIds.count)")

		var deletedCount = 0
		// DynamoDB [`BatchWriteItem` only supports 25 operations at a time](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchWriteItem.html).
		for chunk in processedItemIds.chunks(ofCount: 25) {
			context.logger.info("Deleting chunk of items with count: \(chunk.count)")

			let keyExpressions: [[String: DynamoDbValue]] = chunk.map { ["itemId": .s($0)] }
			let deleteRequests: [DynamoDbClientTypes.DeleteRequest] = keyExpressions.map { .init(key: $0) }
			let writeRequests: [DynamoDbClientTypes.WriteRequest] = deleteRequests.map { .init(deleteRequest: $0) }

			let _ = try await self.dynamoDbClient.batchWriteItem(input: .init(requestItems: [scheduledMovesTableName: writeRequests]))

			deletedCount += writeRequests.count
			context.logger.info("Successfully deleted chunk of item with count: \(writeRequests.count)")
		}

		context.logger.info("Successfully deleted all processed items with count: \(deletedCount)")
		return .init()
	}
}
