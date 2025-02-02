#!/usr/bin/env bash

# Many variables are sourced from build.conf and passed as environment variables to Packer.
# The vm_default_user name will be used by Packer and Ansible.
# (j2 is a better solution than 'envsubst' which messes up '$' in the text unless you specify each variable)
# vm_default_user
# vm_memory
# proxmox_host
# iso_filename
# vm_ver
# vm_id
# proxmox_password
# ssh_password

set -o allexport
build_conf="build.conf"

function help {
    printf "\n"
    echo "$0 (proxmox|debug [VM_ID])"
    echo
    echo "proxmox   - Build and create a Proxmox VM template"
    echo "debug     - Debug Mode: Build and create a Proxmox VM template"
    echo
    echo "VM_ID     - VM ID for new VM template (overrides default from build.conf)"
    echo
    echo "Enter Passwwords when prompted or provide them via ENV variables:"
    echo "(use a space in front of ' export' to keep passwords out of bash_history)"
    echo " export proxmox_password=MyLoginPassword"
    echo " export ssh_password=MyPasswordInVM"
    printf "\n"
    exit 0
}

function die_var_unset {
    echo "ERROR: Variable '$1' is required to be set. Please edit '${build_conf}' and set."
    exit 1
}

## check that data in build_conf is complete
[[ -f $build_conf ]] || { echo "User variables file '$build_conf' not found."; exit 1; }
source $build_conf

[[ -z "$vm_default_user" ]] && die_var_unset "vm_default_user"
[[ -z "$vm_memory" ]] && die_var_unset "vm_memory"
[[ -z "$proxmox_host" ]] && die_var_unset "proxmox_host"
[[ -z "$default_vm_id" ]] && die_var_unset "default_vm_id"
[[ -z "$iso_url" ]] && die_var_unset "iso_url"
if [[ -z "$iso_prestaged" ]]; then
  [[ -z "$iso_sha256_url" ]] && die_var_unset "iso_sha256_url"
  [[ -z "$iso_directory" ]] && die_var_unset "iso_directory"
fi

## check that build-mode (proxmox|debug) is passed to script
target=${1:-}
[[ "${1}" == "proxmox" ]] || [[ "${1}" == "debug" ]] || help

## VM ID for new VM template (overrides default from build.conf)
vm_id=${2:-$default_vm_id}
printf "\n==> Using VM ID: $vm_id with default user: '$vm_default_user'\n"

## template_name is based on name of current directory, check it exists
if [[ -n "$(find . -maxdepth 1 -name '*.pkr.hcl' -print -quit)" ]]; then
  template_name="."
else
  template_name="${PWD##*/}.json"
  [[ -f $template_name ]] || { echo "Template (${template_name}) not found."; exit 1; }
fi


## check that prerequisites are installed
[[ $(packer --version)  ]] || { echo "Please install 'Packer'"; exit 1; }
[[ $(ansible --version)  ]] || { echo "Please install 'Ansible'"; exit 1; }
[[ $(j2 --version)  ]] || { echo "Please install 'j2cli'"; exit 1; }

## If passwords are not set in env variable, prompt for them
[[ -z "$proxmox_password" ]] && printf "\n" && read -s -p "Existing PROXMOX Login Password: " proxmox_password && printf "\n"
printf "\n"

if [[ -z "$ssh_password" ]]; then
    while true; do
        read -s -p "Enter  new SSH Password: " ssh_password
        printf "\n"
        read -s -p "Repeat new SSH Password: " ssh_password2
        printf "\n"
        [ "$ssh_password" = "$ssh_password2" ] && break
        printf "Passwords do not match. Please try again!\n\n"
    done
fi

[[ -z "$proxmox_password" ]] && echo "The Proxmox Password is required." && exit 1
[[ -z "$ssh_password" ]] && echo "The SSH Password is required." && exit 1

## download ISO and Ansible role
if [[ -z "$iso_prestaged" ]]; then

    printf "\n=> Downloading and checking ISO\n\n"
    iso_filename=$(basename $iso_url)
    wget -P $iso_directory -N $iso_url                  # only re-download when newer on the server
    wget --no-verbose $iso_sha256_url -O $iso_directory/SHA256SUMS  # always download and overwrite
    (cd $iso_directory && cat $iso_directory/SHA256SUMS | grep $iso_filename | sha256sum --check)
    if [ $? -eq 1 ]; then echo "ISO checksum does not match!"; exit 1; fi
fi

printf "\n=> Downloading Ansible role\n\n"
# will always overwrite role to get latest version from Github
ansible-galaxy install --force -p playbook/roles -r playbook/requirements.yml
[[ -f playbook/roles/ansible-initial-server/tasks/main.yml ]] || { echo "Ansible role not found."; exit 1; }


mkdir -p http

# Debian & Ubuntu
## Insert the password hashes for root and default user into preseed.cfg using a Jinja2 template
if [[ -f preseed.cfg.j2 ]]; then
    password_hash1=$(mkpasswd -R 1000000 -m sha-512 $ssh_password)
    password_hash2=$(mkpasswd -R 1000000 -m sha-512 $ssh_password)
    printf "\n=> Customizing auto preseed.cfg\n"
    j2 preseed.cfg.j2 > http/preseed.cfg
    [[ -f http/preseed.cfg ]] || { echo "Customized preseed.cfg file not found."; exit 1; }
fi

# OpenBSD
## Insert the password hashes for root and default user into install.conf using a Jinja2 template
if [[ -f install.conf.j2 ]]; then
    password_hash1=$(python3 -c "import os, bcrypt; print(bcrypt.hashpw(os.environ['ssh_password'], bcrypt.gensalt(10)))")
    password_hash2=$(python3 -c "import os, bcrypt; print(bcrypt.hashpw(os.environ['ssh_password'], bcrypt.gensalt(10)))")
    printf "\n=> Customizing install.conf\n"
    j2 install.conf.j2 > http/install.conf
    [[ -f http/install.conf ]] || { echo "Customized install.conf file not found."; exit 1; }
fi

# Centos
if [[ -f ks.cfg.j2 ]]; then
    printf "\n=> Customizing ks.cfg\n"
    j2 ks.cfg.j2 > http/ks.cfg
    [[ -f http/ks.cfg ]] || { echo "Customized install.conf file not found."; exit 1; }
fi

if [[ -f user-data.j2 ]]; then
    password_hash1=$(echo $ssh_password | openssl passwd -6 -stdin)
    password_hash2=$(echo $ssh_password | openssl passwd -6 -stdin)

    printf "\n=> Customizing user-data\n"
    j2 user-data.j2 > http/user-data
    [[ -f http/user-data ]] || { echo "Customized user-data file not found."; exit 1; }
fi

vm_ver=$(git describe --tags)


## Call Packer build with the provided data
case $target in
    proxmox)
        printf "\n==> Build and create a Proxmox template.\n\n"
        ansible_verbosity="-v"
        packer build -on-error=ask $template_name
        ;;
    debug)
        printf "\n==> DEBUG: Build and create a Proxmox template.\n\n"
        ansible_verbosity="-vvvv"
        PACKER_LOG=1 packer build -debug -on-error=ask $template_name
        ;;
    *)
        help
        ;;
esac

## remove file which has the hashed passwords
[[ -f http/preseed.cfg ]] && printf "=> " && rm -v http/preseed.cfg
[[ -f http/install.conf ]] && printf "=> " && rm -v http/install.conf
