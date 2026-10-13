# Thin wrappers. Usage: make plan STACK=40-unity-catalog
STACK ?= 10-foundation
STACKS := 10-foundation 20-identity 30-account 40-unity-catalog 50-workspace 55-ai-platform 60-governance 70-observability

.PHONY: validate test plan-test fmt init plan apply output all-plan

validate:            ## config checks + terraform fmt check
	python3 scripts/validate_config.py
	terraform fmt -recursive -check

test:               ## naming module and validator tests (no cloud access needed)
	python3 tests/naming/run_tests.py

plan-test:          ## mocked plan of every stack (needs provider downloads)
	python3 tests/stacks/run_plan_tests.py

fmt:
	terraform fmt -recursive

init:
	./scripts/tf.sh $(STACK) init

plan: init
	./scripts/tf.sh $(STACK) plan -out tfplan

apply:
	./scripts/tf.sh $(STACK) apply tfplan

output:
	./scripts/tf.sh $(STACK) output

all-plan:
	@for s in $(STACKS); do echo "== $$s"; ./scripts/tf.sh $$s init -input=false >/dev/null && ./scripts/tf.sh $$s plan -input=false -lock=false || exit 1; done
