# --- 1. PROVIDER & BACKEND ---
terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "much-terraform-state"
    key            = "much-to-do/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks-correct"
    encrypt        = true
  }
}

provider "aws" {
  region = "eu-west-1"
}

# --- 2. DATA SOURCES ---
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# --- 3. NETWORKING ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "much-to-do-vpc-simple"
  cidr = "10.0.0.0/16"

  azs            = ["eu-west-1a", "eu-west-1b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway = false
}

# --- 4. SECURITY GROUP ---
resource "aws_security_group" "simple_sg" {
  name   = "much-to-do-simple-sg"
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

# --- 5. EC2 INSTANCES ---
module "ec2_instances" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  count = 2
  name  = "much-to-do-test-${count.index}"

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = element(module.vpc.public_subnets, count.index)
  vpc_security_group_ids      = [aws_security_group.simple_sg.id]
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
# Wait for the system update lock to release
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y golang

cat << 'GOAPP' > /home/ubuntu/main.go
package main
import (
    "fmt"
    "net/http"
)
func main() {
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "Hello! This is a Direct Test of the Much-To-Do Backend.")
    })
    http.ListenAndServe(":8080", nil)
}
GOAPP

chown ubuntu:ubuntu /home/ubuntu/main.go
# Use nohup so the process keeps running after the script exits
sudo -u ubuntu nohup go run /home/ubuntu/main.go > /home/ubuntu/app.log 2>&1 &
EOF
}

# --- 6. OUTPUTS ---
output "backend_ips" {
  description = "Access your app directly using these IPs on port 8080"
  value       = [for i in module.ec2_instances : "http://${i.public_ip}:8080"]
}
