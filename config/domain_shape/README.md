# config/domain_shape/<domain>.yaml

Optional. Approved by the domain team (CODEOWNERS). Declares what this domain adds to, or removes
from, the standard structure. The standard is: the schemas in `config/domains.yaml`, the roles in
`config/access_matrix.yaml`, and the global personas in `config/personas.yaml`.

```yaml
schemas:
  add:
    adjuster_notes: { layer: INFO_MART, comment: "Free-text adjuster notes" }   # volumes: [..] optional
  remove: [ai]                      # a standard schema this domain does not want (never admin)
roles:
  adjuster:                         # creates piq-<env>-<domain>-adjuster in every environment
    description: Claims adjusters
    service_principal_only: false   # true = in the prod environment only service principals may join
personas:
  adjuster-analyst:                 # creates piq-<env>-persona-<domain>-adjuster-analyst
    description: Adjuster who analyses claims data
```

Declaring a schema, role or persona grants nothing. What each role may do is decided in
`config/domain_access/<domain>.yaml`, which platform and governance approve.
