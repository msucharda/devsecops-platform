# Zdrojový repozitář platformy je veřejný

Zdrojový repozitář platformy na github.com je veřejný. Projekt používá licenci MIT, stejně jako AVM a `Azure/alz`. Úplné znění licence je v kořenovém souboru [LICENSE](../../LICENSE). Uživatel schválil licenci MIT pro `v0.1.0` dne 6. 11. 2026 ([#76](https://github.com/msucharda/devsecops-platform/issues/76)). Zákazník stáhne release bez přihlašovacích údajů. Attestaci release podepisuje veřejná instance Sigstore. Autor tak nespravuje přístup jednotlivých zákazníků.

## Considered Options

- Privátní repozitář a token pro každého zákazníka. Zamítnuto: Autor by spravoval přístup každého zákazníka a zákazník by ukládal externí token.
- Release mimo GitHub. Zamítnuto: Release by neměl attestaci z GitHub Actions.

## Consequences

- Soubor `LICENSE` je součástí repozitáře i ZIP assetu release. Kopie a podstatné části softwaru musí zachovat copyright a znění licence MIT.
- Zdrojový repozitář nesmí obsahovat data žádné instance, například ID tenantu, ID subscription nebo název enterprise. Tato data patří do repozitáře instance.

## Přesun vývoje do GHE.com

Uživatel 9. 11. 2026 v návrhovém interview schválil cílové uspořádání:
„Vývoj do GHE.com, veřejný zdrojový kód a release dál publikovat na github.com“.
Každodenní vývoj, issues a interní CI se přesunou do GHE.com. Veřejný zdrojový
kód a release zůstanou dostupné na github.com; zákazník dál stáhne release
bez přihlášení. Toto rozdělení umožní vyvíjet v GHE.com bez zrušení veřejné
distribuce podle tohoto ADR.

Ve stejném interview uživatel schválil samostatnou organizaci pro vývoj
v GHE.com. Tato organizace musí zůstat mimo správu a teardown referenční
instance, aby odstranění instance neodstranilo zdrojový kód, issues ani CI
potřebné k obnově. Rozhodnutí nevyžaduje samostatný enterprise.

Jde o schválený cíl, nikoli o provedenou migraci. Způsob publikace, přenos
historie issues, podmínky přepnutí a návratu i dopad enterprise politik
na vývojovou organizaci zůstávají otevřené. Varianta přesunu veřejné
distribuce pouze do GHE.com nebyla vybraná. Oddělení dat instance
od veřejného zdrojového kódu platí beze změny.

Uživatel potvrdil společné porozumění návrhu; rozhodnutí a otevřené otázky
eviduje návrhové [issue #256](https://github.com/msucharda/devsecops-platform/issues/256).
Nejde o schválenou implementační spec.
