.PHONY: help up down status reset reset-lab check check-all solve preload rebuild clean validate lint e2e command-e2e
help:
	@echo "Targets:"
	@echo "  up / down            create or delete the k3d cluster and the labs"
	@echo "  status               list lab Pods"
	@echo "  check LAB=07         check one lab        check-all   check every deployed lab"
	@echo "  reset-lab LAB=07     redeploy one lab     reset       redeploy all labs"
	@echo "  solve LAB=07         apply the reference repair"
	@echo "  preload [SCOPE=runtime|debug]   load third-party images into the nodes"
	@echo "  rebuild              rebuild the Java images and restart the lab Deployments"
	@echo "  clean                remove leftover node debug and checker Pods"
	@echo "  validate / lint      static checks         e2e / command-e2e   disposable-cluster tests"
up:
	./scripts/up.sh
down:
	./scripts/down.sh
status:
	./scripts/status.sh
reset:
	./scripts/reset-all.sh
reset-lab:
	@test -n "$(LAB)" || (echo "Usage: make reset-lab LAB=07" && exit 2)
	./scripts/reset-lab.sh "$(LAB)"
check:
	@test -n "$(LAB)" || (echo "Usage: make check LAB=07" && exit 2)
	./scripts/check-lab.sh "$(LAB)"
check-all:
	./scripts/check-all.sh
preload:
	./scripts/preload.sh $(if $(SCOPE),--$(SCOPE),--all)
rebuild:
	./scripts/rebuild.sh
clean:
	./scripts/clean.sh
solve:
	@test -n "$(LAB)" || (echo "Usage: make solve LAB=07" && exit 2)
	./scripts/solve-lab.sh "$(LAB)"
validate:
	./scripts/validate.sh
lint:
	shellcheck -S warning scripts/*.sh
e2e:
	./scripts/e2e-test.sh

command-e2e:
	./scripts/command-e2e-test.sh
