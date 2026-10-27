# config/domain_access/<domain>.yaml

Optional. Approved by platform and governance (CODEOWNERS). Decides what the roles of this domain
may do. Anything not listed here follows the standard in `config/access_matrix.yaml`.

```yaml
schemas:                            # schema -> role -> bundle (R, RW, RWC)
  reporting: { analyst: R }         # tighter than the standard row for this domain
  adjuster_notes:                   # a schema added in domain_shape
    producer: RWC
    adjuster: R
  info_mart:
    analyst: { nonprod: RW, prod: R }   # a bundle may differ by tier
product:                            # access of extra roles to this domain's product schemas
  adjuster: R
warehouse:                          # extra roles that may use or manage the domain warehouse
  CAN_USE: [adjuster]
personas:                           # access of each domain persona, per environment
  adjuster-analyst:
    access:
      dev: ["dev:claims:adjuster", "sandbox-users"]
      prd: ["prd:claims:adjuster"]
```

Limits (checked by `scripts/validate_config.py` and the naming module): a bundle can never exceed
`override_ceiling` in `access_matrix.yaml`; the `admin` schema cannot be changed; a domain persona
may only reference roles of its own domain.
