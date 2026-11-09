# Zákazník získá platformu vendoringem release

Zákazník po review importuje tagovaný release platformy do své organizace na GHE.com. Upgrade je import nového tagu. Platforma vyžaduje vendoring pro akce a skilly, proto stejné pravidlo platí i pro platformu. Referenční instance získá release stejným postupem jako zákazník.

## Considered Options

- Přímá konzumace verzovaných modulů z repozitáře platformy. Zamítnuto: Zákazník by závisel na externím zdroji, což platforma u akcí zakazuje.
- Jednorázový fork. Zamítnuto: Zákazník by nemohl přejít na novou verzi.

## Vývojové ověření na referenční instanci

Uživatel 9. 11. 2026 v návrhovém interview schválil ověřování změn nejdřív
na dlouhodobě běžící referenční instanci a jejich následné zobecnění
do platformy. Důvodem je uživatelem hlášená pomalá zpětná vazba při vývoji.

Vývojové ověření není akceptace release. Dokončení změny vyžaduje převzetí
do zdrojového kódu platformy, vydání release a ověření jeho standardního
vendoringu do referenční instance. Samotné ruční zprovoznění změnu
nedokončuje. Zákaznický postup podle tohoto ADR zůstává beze změny.

Ve stejném interview uživatel schválil jako primární cestu změn PR
v repozitáři instance. Změny přes UI nebo přímé API mohou sloužit jen
jako ohraničený, výslovně schválený experiment. Experiment musí evidovat
změněné objekty; po ověření se změna převezme do kódu, nebo vrátí.
Tím se zachová přehled o skutečném stavu instance.

Uživatel dále schválil, že úplný teardown a nové nasazení nepatří
do běžného vývojového cyklu. Plánují se pro akceptační milník nebo změnu
bootstrapu, teardownu či obnovy instance. Každý konkrétní destruktivní běh
vyžaduje samostatné schválení uživatele.

Tato rozhodnutí nepovolují konkrétní živý zásah a nemění nesplněná
akceptační kritéria existujících issues. Nižší četnost teardownu není
důkaz jeho funkčnosti.

## Důkazy dokončení běžné změny

Uživatel ve stejném interview schválil ověřování podle dopadu změny.
Na standardně převzatém release musí být doložené relevantní scénáře:

- funkční živý scénář změněné schopnosti;
- odmítnutí zakázané operace u dotčené kontroly;
- opakovaný apply bez dalších změn;
- kontrola driftu vůči očekávanému stavu.

Vývojová úprava sama tyto důkazy nenahrazuje. Source CI a review zůstávají
povinné podle stávajících pravidel. Nesouvisející otevřená kritéria se
evidují odděleně; neblokují běžnou změnu jen proto, že dosud nejsou ověřená.
Kritérium dotčené změnou se za nesouvisející považovat nesmí.

Uživatel potvrdil společné porozumění návrhu a následně 9. 11. 2026 schválil
aktualizovanou [spec #256](https://github.com/msucharda/devsecops-platform/issues/256)
jako podklad pro tickets. Schválení spec nepovoluje konkrétní živý běh.
Způsob evidence vývojových úprav a jejich úplného převzetí nebo vrácení
upřesňuje [ADR 0019](0019-reference-development-candidates.md).

## Měření délky cyklu

Uživatel 9. 11. 2026 při řešení Q7 ve spec #256 schválil nejdřív měřit
skutečný průběh práce, nikoli stanovit číselný limit bez výchozích dat.
Sledují se dva úseky: od připravené změny po první živý výsledek a odtud
po ověření standardního release. Čas práce, CI a čekání na člověka se
rozlišují.

Číselný cíl se určí následně podle měření. Jeho absence neblokuje migraci;
do jeho stanovení a vyhodnocení se nesmí tvrdit prokázané zrychlení.
