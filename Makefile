.PHONY: build-all run-all docker-build-all minikube

build-all:
	$(MAKE) -C auth-service build

run-all:
	$(MAKE) -C auth-service run

docker-build-all:
	$(MAKE) -C auth-service docker-build

minikube:
	minikube start --cpus=4 --memory=8192 --driver=docker
