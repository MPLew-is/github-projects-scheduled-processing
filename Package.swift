// swift-tools-version: 5.6

import PackageDescription

let package = Package(
	name: "GithubProjectsScheduledProcessing",
	platforms: [
		.macOS(.v12),
	],
	products: [
		.executable(
			name: "GithubProjectsScheduledProcessing",
			targets: ["GithubProjectsScheduledProcessing"]
		),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-algorithms",                from: "1.0.0"),
		.package(url: "https://github.com/swift-server/async-http-client",        from: "1.11.0"),
		.package(url: "https://github.com/swift-server/swift-aws-lambda-runtime", revision: "cb340de265665e23984b1f5de3ac4d413a337804"),
		.package(url: "https://github.com/awslabs/aws-sdk-swift",                 from:     "0.2.5"),
		.package(url: "https://github.com/MPLew-is/deep-codable",                 branch:   "main"),
		.package(url: "https://github.com/MPLew-is/github-graphql-client",        branch:   "main"),
	],
	targets: [
		.executableTarget(
			name: "GithubProjectsScheduledProcessing",
			dependencies: [
				.product(name: "Algorithms",        package: "swift-algorithms"),
				.product(name: "AsyncHTTPClient",   package: "async-http-client"),
				.product(name: "AWSLambdaRuntime",  package: "swift-aws-lambda-runtime"),
				.product(name: "AWSDynamoDB",       package: "aws-sdk-swift"),
				.product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
				.product(name: "DeepCodable",       package: "deep-codable"),
				.product(name: "GithubApiClient",   package: "github-graphql-client"),
			]
		),
	]
)
