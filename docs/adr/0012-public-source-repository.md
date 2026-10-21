# Zdrojový repozitář platformy je veřejný

Zdrojový repozitář platformy na github.com je veřejný. Plánovaná licence je MIT, stejně jako u AVM a `Azure/alz`; do přidání souboru `LICENSE` repozitář licenci neuděluje. Zákazník stáhne release bez přihlašovacích údajů. Attestaci release podepisuje veřejná instance Sigstore. Autor tak nespravuje přístup jednotlivých zákazníků.

## Considered Options

- Privátní repozitář a token pro každého zákazníka. Zamítnuto: Autor by spravoval přístup každého zákazníka a zákazník by ukládal externí token.
- Release mimo GitHub. Zamítnuto: Release by neměl attestaci z GitHub Actions.

## Consequences

- Repozitář je veřejný. Soubor `LICENSE` zatím chybí, protože držitele copyrightu určí schválení zaměstnavatele autora. Do jeho přidání release neuděluje licenci MIT.
- Zdrojový repozitář nesmí obsahovat data žádné instance, například ID tenantu, ID subscription nebo název enterprise. Tato data patří do repozitáře instance.
