     1	This directory contains generated or hand-authored CRDs for the AINETOPS SRv6Service API.
     2	
     3	- bases/ainetops.io_srv6services.yaml: Structural schema with printer columns and status subresource
     4	- RBAC for the controller in deploy/rbac/srv6-crd-rbac.yaml
     5	- Sample CR at config/samples/ainetops_v1alpha1_srv6service.yaml
     6	
     7	Validation contract per specs/001-ainetops-sonic-evpn-fabric/contracts/crd-api.md includes CEL rules.
