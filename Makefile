.PHONY: build-all run-all docker-build-all

build-all:
	$(MAKE) -C auth-service build

run-all:
	$(MAKE) -C auth-service run

docker-build-all:
	$(MAKE) -C auth-service docker-build
