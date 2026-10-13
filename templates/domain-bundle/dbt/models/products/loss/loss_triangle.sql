-- Part of the Loss product: lands in {env}_claims.product_loss.loss_triangle.
-- Built from the domain's business vault, never directly from the raw vault in
-- a consumer-facing view, so consumers need no access to the vault.
select
    c.claim_hk,
    c.accident_year,
    c.development_month,
    sum(c.incurred_amount) as incurred_loss,
    sum(c.paid_amount)     as paid_loss
from {{ ref('claim_development') }} as c
group by all
