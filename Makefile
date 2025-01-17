# Disable built-in rules
MAKEFLAGS += --no-builtin-rules

IMAGE_BASED_DIR = .
SNO_DIR = ./bootstrap-in-place-poc

########################

default: help

.PHONY: checkenv
checkenv:
ifndef PULL_SECRET
	$(error PULL_SECRET must be defined)
endif

SEED_VM_NAME  ?= seed
SEED_VM_IP  ?= 192.168.126.10
SEED_VERSION ?= 4.13.5
SEED_MAC ?= 52:54:00:ee:42:e1

RECIPIENT_VM_NAME ?= recipient
RECIPIENT_VM_IP  ?= 192.168.126.99
RECIPIENT_VERSION ?= 4.14.1
RECIPIENT_MAC ?= 52:54:00:fa:ba:da

LIBVIRT_IMAGE_PATH := $(or ${LIBVIRT_IMAGE_PATH},/var/lib/libvirt/images)

MACHINE_NETWORK ?= 192.168.126.0/24
CPU_CORE ?= 16
RAM_MB ?= 32768
LCA_IMAGE ?= quay.io/openshift-kni/lifecycle-agent-operator:latest
RELEASE_ARCH ?= x86_64

SSH_KEY_DIR = $(SNO_DIR)/ssh-key
SSH_KEY_PUB_PATH = $(SSH_KEY_DIR)/key.pub
SSH_KEY_PRIV_PATH = $(SSH_KEY_DIR)/key

SSH_FLAGS = -o IdentityFile=$(SSH_KEY_PRIV_PATH) \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no

HOST_IP ?= $(SEED_VM_IP)
SSH_HOST = core@$(HOST_IP)

# Default cluster is seed cluster, you can change easily by setting CLUSTER=recipient on the command line
CLUSTER ?= $(SEED_VM_NAME)
SNO_KUBECONFIG ?= $(SNO_DIR)/workdir-$(CLUSTER)/auth/kubeconfig
oc = oc --kubeconfig $(SNO_KUBECONFIG)

$(SSH_KEY_DIR):
	@echo Creating SSH key dir
	mkdir $@

$(SSH_KEY_PRIV_PATH): $(SSH_KEY_DIR)
	@echo "No private key $@ found, generating a private-public pair"
	# -N "" means no password
	ssh-keygen -f $@ -N ""
	chmod 400 $@

$(SSH_KEY_PUB_PATH): $(SSH_KEY_PRIV_PATH)

bootstrap-in-place-poc:
	rm -rf $(SNO_DIR)
	git clone https://github.com/rh-ecosystem-edge/bip-orchestrate-vm

.PHONY: lifecycle-agent
lifecycle-agent:
	@if [ -d lifecycle-agent ]; then \
		git -C lifecycle-agent pull ;\
	else \
		git clone https://github.com/openshift-kni/lifecycle-agent ;\
	fi

## Seed VM management

.PHONY: seed-vm-create
seed-vm-create: VM_NAME=$(SEED_VM_NAME)
seed-vm-create: HOST_IP=$(SEED_VM_IP)
seed-vm-create: RELEASE_VERSION=$(SEED_VERSION)
seed-vm-create: MAC_ADDRESS=$(SEED_MAC)
seed-vm-create: start-iso-abi ## Install seed SNO cluster

.PHONY: wait-for-seed
wait-for-seed: CLUSTER=seed
wait-for-seed: wait-for-install-complete ## Wait for seed cluster to complete installation

.PHONY: seed-ssh
seed-ssh: HOST_IP=$(SEED_VM_IP)
seed-ssh: ssh ## ssh into seed VM

.PHONY: seed-vm-backup
seed-vm-backup: VM_NAME=$(SEED_VM_NAME)
seed-vm-backup: VERSION=$(SEED_VERSION)
seed-vm-backup: vm-backup ## Make a copy of seed VM disk image (qcow2 file)

.PHONY: seed-vm-restore
seed-vm-restore: VM_NAME=$(SEED_VM_NAME)
seed-vm-restore: VERSION=$(SEED_VERSION)
seed-vm-restore: vm-restore ## Restore a copy of seed VM disk image (qcow2 file)

.PHONY: seed-lifecycle-agent-deploy
seed-lifecycle-agent-deploy: CLUSTER=$(SEED_VM_NAME)
seed-lifecycle-agent-deploy: lifecycle-agent-deploy

.PHONY: seed-cluster-prepare
seed-cluster-prepare: dnsmasq-workaround seed-varlibcontainers seed-lifecycle-agent-deploy ## Prepare seed VM cluster

.PHONY: dnsmasq-workaround
# dnsmasq workaround until https://github.com/openshift/assisted-service/pull/5658 is in assisted
dnsmasq-workaround: SEED_CLUSTER_NAME ?= $(SEED_VM_NAME).redhat.com
dnsmasq-workaround: CLUSTER=$(SEED_VM_NAME)
dnsmasq-workaround:
	./generate-dnsmasq-machineconfig.sh --name $(SEED_CLUSTER_NAME) --ip $(SEED_VM_IP) | $(oc) apply -f -

.PHONY: seed-varlibcontainers
seed-varlibcontainers: CLUSTER=$(SEED_VM_NAME)
seed-varlibcontainers: shared-varlibcontainers

.PHONY: vdu
vdu: ## Apply VDU profile to seed VM
	KUBECONFIG=$(SNO_KUBECONFIG) \
		$(IMAGE_BASED_DIR)/vdu-profile.sh

## Recipient VM management
.PHONY: recipient-vm-create
recipient-vm-create: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-create: HOST_IP=$(RECIPIENT_VM_IP)
recipient-vm-create: RELEASE_VERSION=$(RECIPIENT_VERSION)
recipient-vm-create: MAC_ADDRESS=$(RECIPIENT_MAC)
recipient-vm-create: start-iso-abi ## Install recipient SNO cluster

.PHONY: wait-for-recipient
wait-for-recipient: CLUSTER=recipient
wait-for-recipient: wait-for-install-complete ## Wait for recipient cluster to complete installation

.PHONY: recipient-ssh
recipient-ssh: HOST_IP=$(RECIPIENT_VM_IP)
recipient-ssh: ssh ## ssh into recipient VM

.PHONY: recipient-vm-backup
recipient-vm-backup: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-backup: VERSION=$(RECIPIENT_VERSION)
recipient-vm-backup: vm-backup ## Make a copy of recipient VM disk image (qcow2 file)

.PHONY: recipient-vm-restore
recipient-vm-restore: VM_NAME=$(RECIPIENT_VM_NAME)
recipient-vm-restore: VERSION=$(RECIPIENT_VERSION)
recipient-vm-restore: vm-restore ## Restore a copy of recipient VM disk image (qcow2 file)

.PHONY: recipient-lifecycle-agent-deploy
recipient-lifecycle-agent-deploy: CLUSTER=$(RECIPIENT_VM_NAME)
recipient-lifecycle-agent-deploy: lifecycle-agent-deploy

.PHONY: recipient-cluster-prepare
recipient-cluster-prepare: recipient-varlibcontainers oadp-deploy recipient-lifecycle-agent-deploy ## Prepare recipient VM cluster

.PHONY: recipient-varlibcontainers
recipient-varlibcontainers: CLUSTER=$(RECIPIENT_VM_NAME)
recipient-varlibcontainers: shared-varlibcontainers

.PHONY: oadp-deploy
oadp-deploy: CLUSTER=$(RECIPIENT_VM_NAME)
oadp-deploy:
	$(oc) apply -f oadp-operator.yaml
	@echo "Waiting for deployment openshift-adp-controller-manager to be available"; \
	until $(oc) wait deployment -n openshift-adp openshift-adp-controller-manager --for=condition=available=true; do \
		echo -n .;\
		sleep 5; \
	done; echo

## Seed creation
.PHONY: seed-image-create
seed-image-create: credentials/backup-secret.json ## Create seed image using ibu-imager		make seed-image SEED_IMAGE=quay.io/whatever/ostmagic:seed
	scp $(SSH_FLAGS) credentials/backup-secret.json core@$(SEED_VM_NAME):/tmp
	ssh $(SSH_FLAGS) core@$(SEED_VM_NAME) sudo podman run --privileged --rm --pid=host --net=host \
		-v /var:/var \
		-v /var/run:/var/run \
		-v /etc:/etc \
		-v /run/systemd/journal/socket:/run/systemd/journal/socket \
		-v /tmp/backup-secret.json:/tmp/backup-secret.json \
		--entrypoint ibu-imager \
		$(LCA_IMAGE) \
			create --authfile /tmp/backup-secret.json --image $(SEED_IMAGE)


## Seed restoring
.PHONY: seed-image-restore
seed-image-restore: CLUSTER=$(RECIPIENT_VM_NAME)
seed-image-restore: lca-stage-idle lca-wait-for-idle lca-stage-prep lca-wait-for-prep lca-stage-upgrade lca-wait-for-upgrade ## Restore seed image				make lca-seed-restore SEED_IMAGE=quay.io/whatever/ostmagic:seed SEED_VERSION=4.13.5
	@echo "Seed image restoration process complete"
	@echo "Reboot SNO to finish the upgrade process"

.PHONY: lca-logs
lca-logs: CLUSTER=$(RECIPIENT_VM_NAME)
lca-logs: ## Tail through LifeCycle Agent logs
	$(oc) logs -f -c manager -n openshift-lifecycle-agent -l app.kubernetes.io/component=lifecycle-agent

start-iso-abi: checkenv bootstrap-in-place-poc
	< agent-config-template.yaml \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		HOST_MAC=$(MAC_ADDRESS) \
		envsubst > $(SNO_DIR)/agent-config.yaml
	make -C $(SNO_DIR) $@ \
		VM_NAME=$(VM_NAME) \
		HOST_IP=$(HOST_IP) \
		MACHINE_NETWORK=$(MACHINE_NETWORK) \
		CLUSTER_NAME=$(VM_NAME) \
		HOST_MAC=$(MAC_ADDRESS) \
		INSTALLER_WORKDIR=workdir-$(VM_NAME)\
		RELEASE_VERSION=$(RELEASE_VERSION) \
		CPU_CORE=$(CPU_CORE) \
		RELEASE_ARCH=$(RELEASE_ARCH) \
		RAM_MB=$(RAM_MB)

.PHONY: wait-for-install-complete
wait-for-install-complete:
	echo "Waiting for installation to complete"
	@until [ "$$($(oc) get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo -n .; sleep 10; \
	done; \
	echo " DONE"

.PHONY: credentials/backup-secret.json
credentials/backup-secret.json:
	@test '$(BACKUP_SECRET)' || { echo "BACKUP_SECRET must be defined"; exit 1; }
	@mkdir -p credentials
	@echo '$(BACKUP_SECRET)' > credentials/backup-secret.json

.PHONY: lifecycle-agent-deploy
lifecycle-agent-deploy: lifecycle-agent
	KUBECONFIG=../$(SNO_KUBECONFIG) make -C lifecycle-agent install deploy
	@echo "Waiting for deployment lifecycle-agent-controller-manager to be available"; \
	until $(oc) wait deployment -n openshift-lifecycle-agent lifecycle-agent-controller-manager --for=condition=available=true; do \
		echo -n .;\
		sleep 5; \
	done; echo

.PHONY: lca-stage-idle
lca-stage-idle: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-idle: credentials/backup-secret.json
	$(oc) create secret generic seed-pull-secret -n default --from-file=.dockerconfigjson=credentials/backup-secret.json \
		--type=kubernetes.io/dockerconfigjson --dry-run=client -oyaml \
		| $(oc) apply -f -
	SEED_VERSION=$(SEED_VERSION) SEED_IMAGE=$(SEED_IMAGE) envsubst < imagebasedupgrade.yaml | $(oc) apply -f -

.PHONY: lca-wait-for-idle
lca-wait-for-idle: CLUSTER=$(RECIPIENT_VM_NAME)
lca-wait-for-idle:
	$(oc) wait --timeout=30m --for=condition=Idle=true ibu -n default upgrade

.PHONY: lca-stage-prep
lca-stage-prep: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-prep:
	$(oc) patch --type=json ibu -n default upgrade --type merge -p '{"spec": { "stage": "Prep"}}'

.PHONY: lca-wait-for-prep
lca-wait-for-prep: CLUSTER=$(RECIPIENT_VM_NAME)
lca-wait-for-prep:
	$(oc) wait --timeout=30m --for=condition=PrepCompleted=true ibu -n default upgrade

.PHONY: lca-stage-upgrade
lca-stage-upgrade: CLUSTER=$(RECIPIENT_VM_NAME)
lca-stage-upgrade:
	$(oc) patch --type=json ibu -n default upgrade --type merge -p '{"spec": { "stage": "Upgrade"}}'

.PHONY: lca-wait-for-upgrade
lca-wait-for-upgrade: CLUSTER=$(RECIPIENT_VM_NAME)
lca-wait-for-upgrade:
	$(oc) wait --timeout=30m --for=condition=UpgradeCompleted=true ibu -n default upgrade

.PHONY: ssh
ssh: $(SSH_KEY_PRIV_PATH)
	ssh $(SSH_FLAGS) $(SSH_HOST)

.PHONY: shared-varlibcontainers
shared-varlibcontainers:
	$(oc) apply -f ostree-var-lib-containers-machineconfig.yaml
	@echo "Waiting for 98-var-lib-containers to be present in running rendered-master MachineConfig"; \
	until $(oc) get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq 98-var-lib-containers; do \
		echo -n .;\
		sleep 30; \
	done; echo
	$(oc) wait --timeout=20m --for=condition=updated=true mcp master

.PHONY: vm-backup
vm-backup:
	virsh shutdown $(VM_NAME)
	@until virsh domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-backup.qcow2"
	virsh start $(VM_NAME)

.PHONY: vm-restore
vm-restore:
	-virsh destroy $(VM_NAME)
	@until virsh domstate $(VM_NAME) | grep -qx 'shut off' ; do echo -n . ; sleep 5; done; echo
	cp "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME)-$(VERSION)-backup.qcow2" "$(LIBVIRT_IMAGE_PATH)/$(VM_NAME).qcow2"
	virsh start $(VM_NAME)

.PHONY: help
help:
	@gawk -vG=$$(tput setaf 6) -vR=$$(tput sgr0) ' \
		match($$0,"^(([^:]*[^ :]) *:)?([^#]*)## (.*)",a) { \
			if (a[2]!="") {printf "%s%-30s%s %s\n",G,a[2],R,a[4];next}\
			if (a[3]=="") {print a[4];next}\
			printf "\n%-30s %s\n","",a[4]\
		}\
	' $(MAKEFILE_LIST)

