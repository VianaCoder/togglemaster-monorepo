terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate-127214161915"
    key          = "togglemaster/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
