terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "random_uuid" "bucket_random_id" {}

resource "aws_s3_bucket" "bucket" {
  bucket = "dotnet-terraf-bucket"
}

resource "aws_s3_object" "lambda_bundle" {
  bucket = aws_s3_bucket.bucket.id
  key    = "Dotnet.CDK.Lambda.zip"
  source = data.archive_file.lambda_archive.output_path
  etag   = filemd5(data.archive_file.lambda_archive.output_path)
}

data "archive_file" "lambda_archive" {
  type        = "zip"
  source_dir  = "Functions/Dotnet.CDK.Lambda/src/Dotnet.CDK.Lambda/bin/Release/net8.0/publish"
  output_path = "Dotnet.CDK.Lambda.zip"
}

resource "aws_lambda_function" "function" {
  function_name = "dotnet-aws-lmdfunction"
  s3_bucket     = aws_s3_bucket.bucket.id
  s3_key        = aws_s3_object.lambda_bundle.key
  role          = aws_iam_role.lambda_role.arn
  handler       = "Dotnet.CDK.Lambda::Dotnet.CDK.Lambda.Function::FunctionHandler"
  runtime       = "dotnet8"
  depends_on    = [aws_iam_role_policy_attachment.attach_iam_policy_to_iam_role]
}

resource "aws_iam_role" "lambda_role" {
  name               = "tf_Lambda_Function_Role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_iam_policy_to_iam_role" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.iam_policy_for_lambda.arn
}

resource "aws_iam_policy" "iam_policy_for_lambda" {
  name        = "aws_iam_policy_for_terraform_aws_lambda_role"
  description = "AWS IAM Policy for managing aws lambda role"
  policy      = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action   = ["sqs:*"]
        Resource = "*"
        Effect   = "Allow"
      }
    ]
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:SendMessage"]
    resources = ["arn:aws:sqs:*:*:s3-notifications-to-sqs"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.bucket.arn]
    }
  }
}

resource "aws_sqs_queue" "s3-notifications-to-sqs" {
  name   = "s3-notifications-to-sqs"
  policy = data.aws_iam_policy_document.queue.json
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bucket.id

  queue {
     queue_arn = aws_sqs_queue.s3-notifications-to-sqs.arn
    events        = ["s3:ObjectCreated:*"]
   
  }
}

# Attachment of a Managed AWS IAM Policy for Lambda basic execution
resource "aws_iam_role_policy_attachment" "lambda_basic_execution_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attachment of a Managed AWS IAM Policy for Lambda sqs execution
resource "aws_iam_role_policy_attachment" "lambda_basic_sqs_queue_execution_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Attachment of a Managed AWS IAM Policy for SQS Full Access
resource "aws_iam_role_policy_attachment" "lambda_basic_sqs_fullAccess" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_cloudwatch_log_group" "aggregator" {
  name = "/aws/lambda/${aws_lambda_function.function.function_name}"
  retention_in_days = 30
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.s3-notifications-to-sqs.arn
  function_name    = aws_lambda_function.function.function_name
  batch_size       = 10  // Adjust batch size as needed
}
