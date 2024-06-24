#!/bin/bash

set -e

# Function to pull necessary tools and resources
function pull_tools_and_resources() {
  echo "Pulling necessary tools and resources..."

  # Install kind
  if ! command -v kind &> /dev/null; then
    echo "Installing kind..."
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.17.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
  else
    echo "Kind already installed."
  fi

  # Install kubectl
  if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
  else
    echo "Kubectl already installed."
  fi

  # Install Helm
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    echo "Helm already installed."
  fi

  # Clone necessary repositories
  echo "Cloning repositories..."
  git clone https://github.com/prometheus-community/helm-charts.git
  git clone https://github.com/pyrra-dev/pyrra.git
}

# Step 1: Create a Kubernetes cluster with kind
function create_cluster() {
  echo "Creating Kubernetes cluster with kind..."
  kind create cluster --name prometheus-tutorial
  kubectl cluster-info --context kind-prometheus-tutorial
}

# Step 2: Install Prometheus monitoring stack for Kubernetes
function install_prometheus() {
  echo "Installing Prometheus monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
}

# Step 3: Deploy a Python API server with dummy APIs
function deploy_python_api() {
  echo "Deploying Python API server with dummy APIs..."
  cat <<EOF > api-deployment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-api
  namespace: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: python-api
  template:
    metadata:
      labels:
        app: python-api
    spec:
      containers:
      - name: python-api
        image: tiangolo/uvicorn-gunicorn-fastapi:python3.8
        ports:
        - containerPort: 80
        command: ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "80"]
        volumeMounts:
        - mountPath: /app
          name: app-volume
      volumes:
      - name: app-volume
        configMap:
          name: python-api-config
---
apiVersion: v1
kind: Service
metadata:
  name: python-api-service
  namespace: api
spec:
  selector:
    app: python-api
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: python-api-config
  namespace: api
data:
  main.py: |
    from fastapi import FastAPI

    app = FastAPI()

    @app.get("/")
    def read_root():
        return {"message": "Hello World"}

    @app.get("/items/{item_id}")
    def read_item(item_id: int, q: str = None):
        return {"item_id": item_id, "q": q}
EOF

  kubectl apply -f api-deployment.yaml
}

# Step 4: Deploy Pyrra and use it to monitor Python API server's SLA
function deploy_pyrra() {
  echo "Deploying Pyrra to monitor Python API server's SLA..."
#   kubectl apply -f https://raw.githubusercontent.com/pyrra-dev/pyrra/main/manifests/standalone.yaml

  # apply pyrra from repo
  cd kube-prometheus
  # Deploy the CRDs and the Prometheus Operator
  kubectl apply -f ./manifests/setup
  # Deploy all the resource like Prometheus, StatefulSets, and Deployments.
  kubectl apply -f ./manifests/

  cat <<EOF > slo.yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: python-api-slo
  namespace: api
spec:
  target: 99.9
  service: python-api
  indicator:
    prometheus:
      address: http://prometheus-server.monitoring.svc.cluster.local
      query: sum(rate(http_requests_total{job="python-api"}[5m])) by (status)
EOF

  kubectl apply -f slo.yaml
}

# Execute all functions
pull_tools_and_resources
create_cluster
install_prometheus
deploy_python_api
deploy_pyrra

echo "All steps completed successfully!"
