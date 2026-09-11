# Hardware provenance refresh

See hardware-inventory.json for timestamp, exact node/pod/image/resource join.
softmax-main broker read failed EKS authentication and EC2 Karpenter inventory
was empty; production jobs now found through softmax-tournament. Broker only
vends account751442549699, not tournament583928386201 or sandbox015142856185.
Configured tournament profile used for read-only inventory; sandbox profile
used for the owned benchmark host. No cluster or production writes.

Of49 running CTF/paintbot image matches,47 are coworld-ctf-game requesting
1CPU/512Mi without resource limits and2 legacy cogame-paintbot-game request3CPU.
The combined family mix is31 c6a.4xlarge,11 c8i-flex.4xlarge,4 m6a.4xlarge,
2 m7i-flex.2xlarge,1 m5a.2xlarge. Use the JSON to distinguish exact images.
Our m5a.4xlarge is the same family, not the identical size or production node.
Keep its one-logical-CPU test as conservative screening and include common
current production families plus an unpinned burst comparison for final work.
