# actions-catalog

Modul spravuje vendorované akce v organizaci akcí. Workflow v instanci smí používat jen akce z tohoto katalogu.

Předpoklady: `organizations`.

## Pravidla vendoringu

- Každá akce má v organizaci akcí repozitář `{owner}-{repo}`, například `actions-checkout`.
- Repozitář je internal a jeho akce smí používat repozitáře z enterprise.
- Tag ve vendorované kopii odpovídá tagu upstreamu. Workflow pinují akci na SHA commitu.
- Import přepíše vnořené `uses:` na vendorované kopie. Pokud vnořená akce v katalogu chybí, import selže.
- Import ověří attestaci upstreamu, pokud existuje, a otevře PR s diffem. Merge schvaluje security tým.

## Počáteční katalog

| Upstream | Použití |
|---|---|
| `actions/checkout` | Checkout repozitáře. |
| `actions/upload-artifact` | Výstupy modulů mezi joby (ADR 0014). |
| `actions/download-artifact` | Výstupy modulů mezi joby. |
| `actions/create-github-app-token` | Token GitHub App pro plan a apply. |
| `azure/login` | Přihlášení do Azure přes OIDC. |
| `hashicorp/setup-terraform` | Instalace Terraformu. |
