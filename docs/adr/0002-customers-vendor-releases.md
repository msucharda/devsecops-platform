# Zákazník získá platformu vendoringem release

Zákazník po review importuje tagovaný release platformy do své organizace na GHE.com. Upgrade je import nového tagu. Platforma vyžaduje vendoring pro akce a skilly, proto stejné pravidlo platí i pro platformu. Referenční instance získá release stejným postupem jako zákazník.

## Considered Options

- Přímá konzumace verzovaných modulů z repozitáře platformy. Zamítnuto: Zákazník by závisel na externím zdroji, což platforma u akcí zakazuje.
- Jednorázový fork. Zamítnuto: Zákazník by nemohl přejít na novou verzi.
