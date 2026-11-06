# Zdrojový repozitář platformy je veřejný

Zdrojový repozitář platformy na github.com je veřejný. Projekt používá licenci MIT, stejně jako AVM a `Azure/alz`. Úplné znění licence je v kořenovém souboru [LICENSE](../../LICENSE). Uživatel schválil licenci MIT pro `v0.1.0` dne 6. 11. 2026 ([#76](https://github.com/msucharda/devsecops-platform/issues/76)). Zákazník stáhne release bez přihlašovacích údajů. Attestaci release podepisuje veřejná instance Sigstore. Autor tak nespravuje přístup jednotlivých zákazníků.

## Considered Options

- Privátní repozitář a token pro každého zákazníka. Zamítnuto: Autor by spravoval přístup každého zákazníka a zákazník by ukládal externí token.
- Release mimo GitHub. Zamítnuto: Release by neměl attestaci z GitHub Actions.

## Consequences

- Soubor `LICENSE` je součástí repozitáře i ZIP assetu release. Kopie a podstatné části softwaru musí zachovat copyright a znění licence MIT.
- Zdrojový repozitář nesmí obsahovat data žádné instance, například ID tenantu, ID subscription nebo název enterprise. Tato data patří do repozitáře instance.
