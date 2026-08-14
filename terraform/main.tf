terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.region
}

# Public IP of the machine running terraform, used to scope ingress rules.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_cidr      = "${chomp(data.http.my_ip.response_body)}/32"
  allowed_cidr = var.allowed_cidr != "" ? var.allowed_cidr : local.my_cidr
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "msr" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "msr" {
  vpc_id = aws_vpc.msr.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.msr.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.msr.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.msr.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "msr" {
  name        = "${var.name_prefix}-sg"
  description = "MSR node access"
  vpc_id      = aws_vpc.msr.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "MSR HTTPS UI/registry (NodePort)"
    from_port   = var.msr_https_nodeport
    to_port     = var.msr_https_nodeport
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

resource "aws_key_pair" "msr" {
  key_name   = "${var.name_prefix}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_instance" "msr" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.msr.id]
  key_name               = aws_key_pair.msr.key_name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    k0s_version = var.k0s_version
  })

  # cloud-init only runs on first boot; a changed bootstrap script needs a fresh node.
  user_data_replace_on_change = true

  tags = { Name = "${var.name_prefix}-node" }
}

resource "aws_eip" "msr" {
  instance = aws_instance.msr.id
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-eip" }
}
