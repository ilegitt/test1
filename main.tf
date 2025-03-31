provider "aws" {
  region = "eu-north-1"
}

resource "aws_vpc" "myapp-vpc" {
  cidr_block = var.vpc_cidr_block

  tags = {
    Name = "${var.env_prefix}-vpc"
  }
}

resource "aws_subnet" "myapp-subnet-1" {
  vpc_id            = aws_vpc.myapp-vpc.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = var.avail_zone

  tags = {
    Name = "${var.env_prefix}-subnet-1"
  }
}

resource "aws_internet_gateway" "myapp-igw" {
  vpc_id = aws_vpc.myapp-vpc.id

  tags = {
    Name = "${var.env_prefix}-igw"
  }
}

resource "aws_default_route_table" "main-rtb" {
  default_route_table_id = aws_vpc.myapp-vpc.default_route_table_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myapp-igw.id
  }

  tags = {
    Name = "${var.env_prefix}-main-rtb"
  }
}

resource "aws_security_group" "custom-sg" {
  vpc_id = aws_vpc.myapp-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.env_prefix}-default-sg"
  }
}

data "aws_ami" "latest-amazon-linux-image" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

output "aws-ami_id" {
  value = data.aws_ami.latest-amazon-linux-image.id
}

output "ec2_public_ip" {
  value = aws_instance.myapp-server.public_ip
}

resource "tls_private_key" "my_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "ssh-key" {
  key_name   = "server-key"
  public_key = tls_private_key.my_key.public_key_openssh
}

resource "aws_instance" "myapp-server" {
  ami                    = data.aws_ami.latest-amazon-linux-image.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.myapp-subnet-1.id
  vpc_security_group_ids = [aws_security_group.custom-sg.id]
  availability_zone      = var.avail_zone
  associate_public_ip_address = true
  key_name               = aws_key_pair.ssh-key.key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install docker
    service docker start
    usermod -a -G docker ec2-user
    systemctl enable docker

    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    yum install -y aws-cli
    aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin <aws_account_id>.dkr.ecr.eu-north-1.amazonaws.com

    mkdir /home/ec2-user/app
    cd /home/ec2-user/app

    cat <<EOL > docker-compose.yml
    version: '3.8'
    services:
      web:
        image: 180294207856.dkr.ecr.eu-north-1.amazonaws.com/master:latest
        ports:
          - '8080:8080'
        environment:
          - POSTGRES_HOST=postgres
          - POSTGRES_DB=mydatabase
          - POSTGRES_USER=myuser
          - POSTGRES_PASSWORD=mypassword
      postgres:
        image: postgres:latest
        environment:
          POSTGRES_USER: myuser
          POSTGRES_PASSWORD: mypassword
          POSTGRES_DB: mydatabase
        ports:
          - '5432:5432'
        volumes:
          - postgres_data:/var/lib/postgresql/data

    volumes:
      postgres_data:
    EOL

    if command -v docker-compose &> /dev/null; then docker-compose up -d; else echo "Docker Compose not found, installation might have failed."; fi
  EOF

  tags = {
    Name = "${var.env_prefix}-server"
  }
}
