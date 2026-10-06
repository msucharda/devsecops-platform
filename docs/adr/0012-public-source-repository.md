# Zdrojový repozitář platformy je veřejný

Zdrojový repozitář platformy na github.com je veřejný a má licenci MIT, stejně jako AVM a `Azure/alz`. Zákazník stáhne release bez přihlašovacích údajů. Attestaci release podepisuje veřejná instance Sigstore. Autor tak nespravuje přístup jednotlivých zákazníků.

## Considered Options

- Privátní repozitář a token pro každého zákazníka. Zamítnuto: Autor by spravoval přístup každého zákazníka a zákazník by ukládal externí token.
- Release mimo GitHub. Zamítnuto: Release by neměl attestaci z GitHub Actions.

## Consequences

- Repozitář zůstane privátní, dokud zveřejnění neschválí zaměstnavatel autora. Soubor `LICENSE` vznikne při zveřejnění, protože držitele copyrightu určí schválení.
- Zdrojový repozitář nesmí obsahovat data žádné instance, například ID tenantu, ID subscription nebo název enterprise. Tato data patří do repozitáře instance.
