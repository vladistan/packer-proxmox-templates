variable "ansible_verbosity" {
  type    = string
  default = "${env("ansible_verbosity")}"
}

variable "iso_url" {
  type    = string
  default = "${env("iso_url")}"
}

variable "proxmox_host" {
  type    = string
  default = "${env("proxmox_host")}"
}

variable "proxmox_password" {
  type      = string
  default   = "${env("proxmox_password")}"
  sensitive = true
}

variable "proxmox_url" {
  type    = string
  default = "${env("proxmox_url")}"
}

variable "proxmox_username" {
  type    = string
  default = "root@pam"
}

variable "ssh_password" {
  type      = string
  default   = "${env("ssh_password")}"
  sensitive = true
}

variable "ssh_username" {
  type    = string
  default = "root"
}

variable "ssh_agent_auth" {
  default = "${env("ssh_agent_auth")}"
}

variable "template_description" {
  type    = string
  default = "Ubuntu 22.04 x86_64 template built with packer (${env("vm_ver")}). Username: ${env("vm_default_user")}"
}

variable "vm_default_user" {
  type    = string
  default = "${env("vm_default_user")}"
}

variable "vm_id" {
  type    = string
  default = "${env("vm_id")}"
}

variable "vm_memory" {
  type    = string
  default = "${env("vm_memory")}"
}

variable "vm_name" {
  type    = string
  default = "ubuntu2204-tmpl"
}

source "proxmox" "ubuntu" {
  
  boot_wait    = "10s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net;seedfrom=http://{{.HTTPIP}}:{{.HTTPPort}}/\"",
    "<enter><wait><wait><wait>",
    "initrd <wait>/casper/<wait>initrd<wait>",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]

  username             = "${var.proxmox_username}"
  password             = "${var.proxmox_password}"
  proxmox_url          = "${var.proxmox_url}"

  ssh_username         = "${var.ssh_username}"
  ssh_agent_auth       = "${var.ssh_agent_auth}"
  ssh_timeout          = "35m"
  
  cores        = "2"
  cpu_type     = "host"
  memory       = "${var.vm_memory}"


  disks {
    disk_size         = "8G"
    format            = "raw"
    storage_pool      = "Z8"
    storage_pool_type = "directory"
    type              = "sata"
  }
  http_directory           = "http"
  insecure_skip_tls_verify = true
  iso_file                 = "${var.iso_url}"
  
  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  node                 = "${var.proxmox_host}"
  os                   = "l26"
 



  template_description = "${var.template_description}"
  unmount_iso          = true

  vm_id                = "${var.vm_id}"
  vm_name              = "${var.vm_name}"
}

build {
  description = "Build Ubuntu 22.04 (focal) x86_64 Proxmox template"

  sources = ["source.proxmox.ubuntu"]

  provisioner "ansible" {
    ansible_env_vars = ["ANSIBLE_CONFIG=./playbook/ansible.cfg", "ANSIBLE_FORCE_COLOR=True"]
    extra_arguments  = ["${var.ansible_verbosity}", "--extra-vars", "vm_default_user=${var.vm_default_user}", "--tags", "all,is_template", "--skip-tags", "openbsd,alpine,centos"]
    playbook_file    = "./playbook/server-template.yml"
  }

  post-processor "shell-local" {
    inline         = ["qm set ${var.vm_id} --scsihw virtio-scsi-pci --serial0 socket --vga serial0"]
    inline_shebang = "/bin/bash -e"
  }
}
