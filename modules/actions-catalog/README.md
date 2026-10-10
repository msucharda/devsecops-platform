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
| `actions/create-github-app-token` | Vydání installation tokenu; zvolená verze musí podporovat potřebná oprávnění a GHE.com (ADR 0016). |
| `azure/login` | Přihlášení do Azure přes OIDC. |
| `hashicorp/setup-terraform` | Instalace Terraformu. |

## Identita

GitHub API používá installation tokeny podle ADR 0016. Plan čte jen prostředky katalogu; apply a vendoring mají potřebná oprávnění k zápisu. PR importu vytvořený App nesmí automaticky získat plan credentials; cloudový plan proběhne po review a merge na chráněné větvi `main`.
