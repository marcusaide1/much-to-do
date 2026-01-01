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

# --- 1. NEW: Ubuntu AMI Lookup ---
# This ensures we get the correct, latest Ubuntu 24.04 image for eu-west-1
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# --- 2. Networking (VPC) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "much-to-do-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  map_public_ip_on_launch = true
  enable_nat_gateway      = false 
  
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# --- 3. Security Group ---
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

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. IAM & CloudWatch ---
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

# --- 5. Frontend (COMMENTED OUT) ---
/*
resource "aws_s3_bucket" "frontend" {
  bucket = "much-to-do-frontend-assets"
}
... (CloudFront config)
*/

# --- 6. Backend (Ubuntu EC2) ---
module "ec2_instances" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  count = 2
  name  = "much-to-do-backend-${count.index}"

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = element(module.vpc.public_subnets, count.index)
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.backend_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  # UBUNTU OPTIMIZED USER DATA
  user_data = <<-EOF
              #!/bin/bash
              # Ubuntu uses apt, not yum
              export DEBIAN_FRONTEND=noninteractive
              apt-get update -y
              apt-get install -y golang
              
              # Create app in the correct /home/ubuntu directory
              cat << 'GOAPP' > /home/ubuntu/main.go
              package main
              import (
                "fmt"
                "net/http"
              )
              func main() {
                http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
                  fmt.Fprintf(w, "Hello from Much-To-Do Backend on Ubuntu!")
                })
                http.ListenAndServe(":8080", nil)
              }
              GOAPP
              
              # Ensure the ubuntu user owns the file and run it
              chown ubuntu:ubuntu /home/ubuntu/main.go
              sudo -u ubuntu go run /home/ubuntu/main.go &
              EOF

  tags = { Name = "much-to-do-backend-${count.index}" }
}

# --- 7. Outputs ---
output "backend_public_ips" {
  value = module.ec2_instances[*].public_ip
}
