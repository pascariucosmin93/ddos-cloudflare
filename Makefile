REGISTRY ?= your-registry
TAG ?= latest

.PHONY: build push deploy

build:
	docker build -t $(REGISTRY)/ddos-agent:$(TAG) ./agent
	docker build -t $(REGISTRY)/ddos-controller:$(TAG) ./controller

push:
	docker push $(REGISTRY)/ddos-agent:$(TAG)
	docker push $(REGISTRY)/ddos-controller:$(TAG)

deploy:
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/rbac.yaml
	kubectl apply -f k8s/configmap.yaml
	kubectl apply -f k8s/daemonset.yaml
	kubectl apply -f k8s/deployment.yaml

status:
	kubectl get all -n ddos-protection

logs-agent:
	kubectl logs -n ddos-protection -l app=ddos-agent --tail=50 -f

logs-controller:
	kubectl logs -n ddos-protection -l app=ddos-controller --tail=50 -f
