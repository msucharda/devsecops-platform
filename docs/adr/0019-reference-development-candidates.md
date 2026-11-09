# Referenční instance ověřuje explicitní development kandidáty

Stávající kontrola `tools/Test-DeploymentRelease.ps1` ověřuje přesný
obsah release před použitím deployment credentials. Ruční úprava
vendorovaného kódu není platný release a standardní cesta ji správně odmítá.
Samotný PR repozitáře instance proto nestačí k ověření změny kódu před
jejím zobecněním do platformy.

Uživatel 9. 11. 2026 při řešení Q6 ve spec
[#256](https://github.com/msucharda/devsecops-platform/issues/256) schválil
samostatný development mode pouze pro referenční instanci. Development
candidate tvoří ověřený výchozí release a přesná změna z PR repozitáře
instance. Záznam svazuje výchozí release, commit PR, hash kandidáta
a jeho schválení. Změna kandidáta zneplatní původní schválení.

Development mode musí mít vlastní validaci původu, integrity a schválení
v důvěryhodné cestě mimo kandidáta. Kandidát si nesmí sám povolit běh
ani rozhodnout o své autorizaci. Stávající kontroly autorů, tokenů,
oprávnění a schvalování živých zásahů zůstávají platné. Nejde o přepínač
pro přeskočení ověření release. Standardní cesta zákazníka se nemění
a development kandidáta nesmí přijmout jako platný release.

Uživatel dále schválil verzovaný záznam v neveřejném repozitáři instance
s odkazy na PR a důkazy běhu. Záznam zahrnuje výchozí release, přesnou
změnu, schválení, výsledek a následné převzetí do standardního release
nebo vrácení. Samotný záznam nedává právo ke spuštění. Zdrojový repozitář
platformy obsahuje jen zobecněný výsledek bez dat instance.

## Considered Options

- Standardní release candidate před každým živým ověřením změny kódu.
  Nevybráno: uživatel chce nejdřív ověřit změnu v běžící referenční instanci
  a potom ji zobecnit do platformy.
- Vývojový strom bez vazby na ověřený release. Nevybráno: ztratil by
  jednoznačný základ změny a komplikoval by reprodukci i návrat.
- Vypnutí integrity release. Nepřípustné: zaměnilo by neověřený obsah
  za standardní release a oslabilo dosavadní hranici důvěry.

## Consequences

- Release candidate je stále standardní publikovaný release; development
  candidate je samostatný vývojový vstup, ne jeho synonymum.
- Implementace musí prokázat omezení na referenci, kontrolu před předáním
  credentials a odmítnutí kandidáta se změněným obsahem, neplatným původem
  nebo chybějícím či neplatným schválením.
- Dokončení změny dál vyžaduje standardní release a jeho ověření podle
  [ADR 0002](0002-customers-vendor-releases.md). Vývojový úspěch nestačí.
- Jde o přijatý návrhový kontrakt, nikoli implementovaný režim nebo souhlas
  s konkrétním živým během. Implementace podléhá security checkpointu
  a ostatním pravidlům repozitáře.
