This folder contains proof slices for Phase 3.
- deploy/kubenet/install.sh.slice.txt shows the script now applying pinned upstream Kubenet/KUID CRDs from versions.lock.yaml commits.
- deploy/sdc/install.sh.slice.txt shows the script now applying pinned upstream SDC CRDs from versions.lock.yaml release.
- deploy/kubenet/srv6-pools.yaml.slice.txt shows the added dedicated SRv6 SID pool and claim, in addition to locator and service-ID pools.
- deploy.kubenet.crds.yaml.slice.txt, deploy.kuid.crds.yaml.slice.txt, deploy.sdc.crds.yaml.slice.txt reflect previous placeholder files; acceptance now hinges on install scripts applying upstream CRDs.
