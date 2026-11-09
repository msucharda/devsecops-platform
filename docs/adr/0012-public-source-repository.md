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

Jde o schválený cíl, nikoli o provedenou migraci. Varianta přesunu veřejné
distribuce pouze do GHE.com nebyla vybraná. Oddělení dat instance
od veřejného zdrojového kódu platí beze změny.

Uživatel potvrdil společné porozumění návrhu. Následně 9. 11. 2026 vyřešil
otázky Q1 až Q7 a schválil aktualizovanou
[spec #256](https://github.com/msucharda/devsecops-platform/issues/256)
jako podklad pro tickets. Schválení spec nepovoluje migraci, živý běh
ani merge návrhového PR. Předání do implementace dál vyžaduje přijetí
návrhového PR a schválený graf tickets podle vývojového postupu.

## Publikační kontrakt

Uživatel 9. 11. 2026 při řešení otázky Q1 ve spec #256 schválil:

- GHE.com je jediným místem přijímání změn platformy. Publikace na
  github.com je jednosměrná; nevzniká druhá vývojová linie.
- Veřejná kopie získá nový kód při přípravě release, včetně release
  candidate, nikoli při každém merge. Pracovní větve, interní issues
  a PR zůstávají v GHE.com.
- Build, attestace původu a vydání release zůstávají na github.com.
  Vstupem je veřejně publikovaná zdrojová revize.
- Publikace zachová původní commity a jejich SHA z GHE.com. Kontrola
  veřejného obsahu musí zahrnout celou přenášenou historii včetně
  commit messages, nikoli jen výsledný strom souborů.

Zachování SHA umožní přímo propojit interní CI, veřejný build a release.
Publikace pouze zdrojových snapshotů s novým SHA nebyla vybraná, protože
by vyžadovala samostatné mapování původu. Ponechání buildu na github.com
zachovává stávající veřejný původ attestace.

## Přenos rozpracované práce

Uživatel ve stejném interview při řešení Q2 schválil přenos otevřených
issues s potřebným kontextem, blokacemi a odkazy na důkazy. Uzavřená issues
a původní PR zůstanou dohledatelné na github.com. Přenos musí zachovat
mapování původního odkazu na nový záznam. Nejde o archivaci celého veřejného
repozitáře, který musí dál vydávat release.

PR otevřené před přepnutím se nejdřív řádně dokončí na github.com,
nebo výslovně odloží do issue a původní PR se uzavře. Tím se nepřenášejí
schválení ani rozpracovaná review mezi hosty. Rozhodnutí není souhlasem
s konkrétním merge nebo uzavřením PR.

## Identita veřejné publikace

Uživatel při řešení Q3 schválil samostatnou publikační GitHub App
s přístupem jen k veřejnému repozitáři. Publikace nesmí používat osobní
PAT ani oprávnění k Azure nebo správě referenční instance. Vývojové CI,
publikační identita a identity instance zůstávají oddělené.

Potřebná oprávnění App musí doložit konkrétní operace přenosu a nesmějí
obejít ruleset. Toto rozhodnutí nepovoluje vytvoření App, přidání
oprávnění ani vložení přihlašovacích údajů.

Omezení sdíleného enterprise a hranici správy vývojové organizace
upřesňuje [ADR 0004](0004-instance-owns-enterprise-and-tenant.md).

## Podmínky přepnutí

Uživatel při řešení Q5 schválil přepnutí každodenní práce až po úplném
průchodu jednoho release candidate: PR a CI v GHE.com, publikace stejného
SHA, build a attestace na github.com a standardní import do reference.
Před přepnutím se také vypořádají původní PR a předá stav otevřených issues.
Dokončení celé #246 ani teardown nejsou automatickým předpokladem;
blokuje jen konkrétní problém znemožňující tento průchod nebo bezpečnou správu.

Ostré přepnutí i případný návrat schvaluje uživatel. Určený implementátor
připraví a provede konkrétně schválené kroky. Do přepnutí zůstává github.com
dosavadním místem práce. Při neúspěšné zkoušce se přepnutí zastaví a stav
se zachová pro opravu; nejde o dokončenou migraci. Návrat po přepnutí
nesmí ztratit mezitím přijaté změny ani evidenci práce.
