provider "aws" {
  region = "eu-west-1"
}

terraform {
  backend "s3" {
    bucket         = "much-terraform-state"
    key            = "much-to-do/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks-correct"
    encrypt        = true
  }
}

# --- New: Dynamic AMI Lookup ---
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# --- 1. Networking (VPC) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "much-to-do-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = false 
  
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# --- 2. Security Group ---
resource "aws_security_group" "backend_sg" {
  name   = "much-to-do-backend-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 3. IAM & CloudWatch ---
resource "aws_iam_role" "ec2_log_role" {
  name = "much-to-do-ec2-log-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_policy" {
  role       = aws_iam_role.ec2_log_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "much-to-do-ec2-profile"
  role = aws_iam_role.ec2_log_role.name
}

# --- 4. Frontend (S3 Only for now) ---
resource "aws_s3_bucket" "frontend" {
  bucket = "much-to-do-frontend-assets"
}

# CLOUDFRONT IS DISABLED UNTIL ACCOUNT IS VERIFIED
# resource "aws_cloudfront_distribution" "s3_distribution" { ... }

# --- 5. Backend (EC2 in Public Subnets) ---
module "ec2_instances" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  count = 2
  name  = "much-to-do-backend-${count.index}"

  # Fixed: Using the dynamic AMI ID from the data source
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  
  subnet_id              = element(module.vpc.public_subnets, count.index)
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  tags = { Name = "much-to-do-backend-${count.index}" }
}

# --- 6. Outputs ---
output "backend_public_ips" {
  value = module.ec2_instances[*].public_ip
}
