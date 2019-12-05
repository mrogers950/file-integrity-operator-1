# Operator variables
# ==================
export APP_NAME=file-integrity-operator

# Container image variables
# =========================
IMAGE_REPO?=docker.io/mrogers950
RUNTIME?=podman

# Image path to use. Set this if you want to use a specific path for building
# or your e2e tests. This is overwritten if we bulid the image and push it to
# the cluster or if we're on CI.
IMAGE_PATH?=$(IMAGE_REPO)/$(APP_NAME)

# Image tag to use. Set this if you want to use a specific tag for building
# or your e2e tests.
TAG?=latest

# Build variables
# ===============
CURPATH=$(PWD)
TARGET_DIR=$(CURPATH)/build/_output
GOPROXY_SETTINGS?=
GO=$(GOPROXY_SETTINGS) GO111MODULE=on go
GOBUILD=$(GO) build
BUILD_GOPATH=$(TARGET_DIR):$(CURPATH)/cmd
TARGET=$(TARGET_DIR)/bin/$(APP_NAME)
MAIN_PKG=cmd/manager/main.go
PKGS=$(shell go list ./... | grep -v -E '/vendor/|/test|/examples')

# go source files, ignore vendor directory
SRC = $(shell find . -type f -name '*.go' -not -path "./vendor/*" -not -path "./_output/*")


# Kubernetes variables
# ====================
KUBECONFIG?=$(HOME)/.kube/config
export NAMESPACE?=openshift-file-integrity

# Operator-sdk variables
# ======================
SDK_VERSION?=v0.12.0
OPERATOR_SDK_URL=https://github.com/operator-framework/operator-sdk/releases/download/$(SDK_VERSION)/operator-sdk-$(SDK_VERSION)-x86_64-linux-gnu
OPERATOR_SDK=$(GOPROXY_SETTINGS) $(GOPATH)/bin/operator-sdk

# Test variables
# ==============
TEST_OPTIONS?=
# Skip pushing the container to your cluster
E2E_SKIP_CONTAINER_PUSH?=false

.PHONY: all
all: build verify test-unit ## Test and Build the file-integrity-operator

.PHONY: help
help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


.PHONY: image
image: fmt operator-sdk ## Build the file-integrity-operator container image
	$(OPERATOR_SDK) build $(IMAGE_PATH) --image-builder $(RUNTIME)

.PHONY: build
build: fmt ## Build the file-integrity-operator binary
	$(GO) build -o $(TARGET) github.com/openshift/file-integrity-operator/cmd/manager

.PHONY: operator-sdk
operator-sdk:
ifeq ("$(wildcard $(GOPATH)/bin/operator-sdk)","")
	wget -nv $(OPERATOR_SDK_URL) -O $(GOPATH)/bin/operator-sdk || (echo "wget returned $$? trying to fetch operator-sdk. please install operator-sdk and try again"; exit 1)
	chmod +x $(GOPATH)/bin/operator-sdk
endif

.PHONY: run
run: operator-sdk ## Run the file-integrity-operator locally
	WATCH_NAMESPACE=$(NAMESPACE) \
	KUBERNETES_CONFIG=$(KUBECONFIG) \
	OPERATOR_NAME=$(APP_NAME) \
	$(OPERATOR_SDK) up local --namespace $(NAMESPACE)

.PHONY: clean
clean: clean-modcache clean-cache clean-output ## Clean the golang environment

.PHONY: clean-output
clean-output:
	rm -rf $(TARGET_DIR)

.PHONY: clean-cache
clean-cache:
	$(GO) clean -cache -testcache $(PKGS)

.PHONY: clean-modcache
clean-modcache:
	$(GO) clean -modcache $(PKGS)

.PHONY: fmt
fmt:  ## Run the `go fmt` tool
	@$(GO) fmt $(PKGS)

.PHONY: simplify
simplify:
	@gofmt -s -l -w $(SRC)

.PHONY: verify
verify: vet mod-verify gosec ## Run code lint checks

.PHONY: vet
vet:
	@$(GO) vet $(PKGS)

.PHONY: mod-verify
mod-verify:
	@$(GO) mod verify

.PHONY: gosec
gosec:
	@$(GO) run github.com/securego/gosec/cmd/gosec -severity medium -confidence medium -quiet ./...

.PHONY: generate
generate: operator-sdk ## Run operator-sdk's code generation (k8s and openapi)
	$(OPERATOR_SDK) generate k8s
	$(OPERATOR_SDK) generate openapi

.PHONY: test-unit
test-unit: fmt ## Run the unit tests
	@$(GO) test $(TEST_OPTIONS) $(PKGS)

# This runs the end-to-end tests. If not running this on CI, it'll try to
# push the operator image to the cluster's registry. This behavior can be
# avoided with the E2E_SKIP_CONTAINER_PUSH environment variable.
.PHONY: e2e
ifeq ($(E2E_SKIP_CONTAINER_PUSH), false)
e2e: namespace operator-sdk check-if-ci image-to-cluster ## Run the end-to-end tests
else
e2e: namespace operator-sdk check-if-ci
endif
	@echo "Running e2e tests"
	$(OPERATOR_SDK) test local ./tests/e2e --image "$(IMAGE_PATH)" --namespace "$(NAMESPACE)" --go-test-flags "-v"

# This checks if we're in a CI environment by checking the IMAGE_FORMAT
# environmnet variable. if we are, lets ues the image from CI and use this
# operator as the component.
#
# The IMAGE_FORMAT variable comes from CI. It is of the format:
#     <image path in CI registry>:${component}
# Here define the `component` variable, so, when we overwrite the
# IMAGE_PATH variable, it'll expand to the component we need.
.PHONY: check-if-ci
check-if-ci:
ifdef IMAGE_FORMAT
	@echo "IMAGE_FORMAT variable detected. We're in a CI enviornment."
	$(eval component = $(APP_NAME))
	$(eval IMAGE_PATH = $(IMAGE_FORMAT))
else
	@echo "IMAGE_FORMAT variable missing. We're in local enviornment."
endif

# If IMAGE_FORMAT is not defined, it means that we're not running on CI, so we
# probably want to push the file-integrity-operator image to the cluster we're
# developing on. This target exposes temporarily the image registry, pushes the
# image, and remove the route in the end.
.PHONY: image-to-cluster
ifdef IMAGE_FORMAT
image-to-cluster:
	@echo "We're in a CI environment, skipping image-to-cluster target."
else
image-to-cluster: namespace openshift-user image
	@echo "Temporarily exposing the default route to the image registry"
	@oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
	@echo "Pushing image $(IMAGE_PATH):$(TAG) to the image registry"
	IMAGE_REGISTRY_HOST=$$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}'); \
		$(RUNTIME) login --tls-verify=false -u $(OPENSHIFT_USER) -p $(shell oc whoami -t) $${IMAGE_REGISTRY_HOST}; \
		$(RUNTIME) push --tls-verify=false $(IMAGE_PATH):$(TAG) $${IMAGE_REGISTRY_HOST}/$(NAMESPACE)/$(APP_NAME):$(TAG)
	@echo "Removing the route from the image registry"
	@oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":false}}' --type=merge
	$(eval IMAGE_PATH = image-registry.openshift-image-registry.svc:5000/$(NAMESPACE)/$(APP_NAME):$(TAG))
endif

.PHONY: namespace
namespace:
	@echo "Creating '$(NAMESPACE)' namespace/project"
	@oc create -f deploy/ns.yaml || true

.PHONY: openshift-user
openshift-user:
ifeq ($(shell oc whoami),kube:admin)
	$(eval OPENSHIFT_USER = kubeadmin)
else
	$(eval OPENSHIFT_USER = $(oc whoami))
endif

.PHONY: push
push: image
	$(RUNTIME) tag $(IMAGE_PATH) $(IMAGE_PATH):$(TAG)
	$(RUNTIME) push $(IMAGE_PATH):$(TAG)
