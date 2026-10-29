# DevSecOps Platform

Modulární vývojová platforma pro zákazníky s GHE.com a EMU: enterprise a organizace GitHubu, Sovereign Landing Zone v Azure a kontroly v dodávce softwaru.

Termíny jsou anglicky, protože je používá kód. Český ekvivalent v závorce používají materiály pro uživatele.

## Language

### Platforma

**Platform** (platforma):
Sada modulů, ze kterých zákazník sestaví vývojovou platformu od enterprise GitHubu a landing zone v Azure po kontroly v dodávce softwaru.
_Avoid_: řešení, akcelerátor

**Instance** (instance):
Jedno nasazení platformy: jeden enterprise EMU na GHE.com, jeden tenant Entra ID a jedna Sovereign Landing Zone. Instance jde nasadit a odstranit jako celek.
_Avoid_: prostředí, deployment

**Reference instance** (referenční instance):
Instance autora platformy, na které autor testuje release. Referenční instance získá release stejným postupem jako zákazník.
_Avoid_: testovací prostředí, demo

**Release** (release):
Tagovaná verze platformy. Release má jednu verzi SemVer pro všechny moduly.
_Avoid_: verze modulu, balíček

**Instance repository** (repozitář instance):
Repozitář v organizaci platformy s vendorovaným release, konfigurací instance a workflow nasazení. Každá instance má jeden repozitář instance.
_Avoid_: config repo, alz-mgmt

**Instance configuration** (konfigurace instance):
Soubor `instance.yaml` v repozitáři instance. Určuje vybrané moduly, jejich parametry a potvrzené ruční kroky.
_Avoid_: tfvars, nastavení

**Drift** (drift):
Rozdíl mezi stavem instance v GitHubu nebo Azure a kódem v repozitáři instance, který vznikl mimo workflow nasazení.
_Avoid_: odchylka, nesoulad

**Teardown** (odstranění instance):
Odstranění všech modulů instance v obráceném pořadí předpokladů. Teardown zachová ruční předpoklady.
_Avoid_: destroy, smazání instance

**Module** (modul):
Jedna samostatně nasaditelná schopnost platformy, například baseline organizace, povinná workflow nebo povýšení image. Modul poskytuje jednu nebo více kontrol. Modul může vyžadovat jiné moduly jako předpoklad.
_Avoid_: akcelerátor, komponenta

**Module manifest** (manifest modulu):
Soubor `module.yaml` v adresáři modulu. Deklaruje předpoklady, deployment phases a ruční kroky modulu.
_Avoid_: metadata

**Deployment phase** (nasazovací fáze):
Pojmenovaná část nasazení modulu s vlastními předpoklady. Umožňuje nasadit část modulu před jinými moduly a zbytek až po nich. Nejde o fázi oprávnění plan nebo apply.
_Avoid_: fáze bez upřesnění

**Manual step** (ruční krok):
Krok modulu, který platforma neumí provést přes API, například nastavení politiky Copilotu. Na rozdíl od ručního předpokladu patří ruční krok k modulu a platformní tým ho provede po nasazení modulu.
_Avoid_: checklist, TODO

**Prerequisite** (předpoklad):
Modul nebo deployment phase, které jiný modul či deployment phase vyžaduje. Výběr nasazované části zahrne i její předpoklady.
_Avoid_: závislost

**Manual prerequisite** (ruční předpoklad):
Podmínka instance, kterou platforma neumí vytvořit: tenant Entra ID, enterprise EMU s nastaveným OIDC a SCIM, první enterprise owner, neautomatizované enterprise kontroly, subscriptions a licence. Platformní tým ji splní před bootstrapem a teardown ji zachová.
_Avoid_: předpoklad bez upřesnění, požadavek

**Deployment identifier** (identifikátor nasazení):
Krátký řetězec, který vznikne při nasazení instance. Je jen v názvech Azure prostředků a organizací GitHubu, jejichž název zůstává po smazání blokovaný.
_Avoid_: suffix, salt

**Primary region** (primární region):
Region Azure, ve kterém běží všechny moduly instance.
_Avoid_: hlavní region, default region

**Secondary region** (sekundární region):
Volitelný druhý region Azure instance. Ve verzi 1 v něm je jen druhý hub konektivity.
_Avoid_: DR region, záložní region

**Control** (kontrola):
Mechanismus, který zachytí incident. Advisory control jen doporučuje, enforcing control vynucuje.
_Avoid_: guardrail, ochrana

**Customer** (zákazník):
Organizace, která nasadí instanci platformy do svého enterprise EMU na GHE.com a svého tenantu Entra ID.
_Avoid_: klient, tenant

**Vendoring** (vendoring):
Převzetí externího kódu do organizace zákazníka jako kopie po review, s pinovanou verzí a určeným vlastníkem. Platí pro akce, skilly i release platformy.
_Avoid_: mirror, import

### Týmy

**Platform team** (platformní tým):
Tým zákazníka, který vlastní instanci a mění ji jen přes PR.
_Avoid_: admin tým, ops

**Security team** (security tým):
Tým zákazníka, který schvaluje vendoring a změny kontrol.
_Avoid_: SOC, bezpečáci

**Workload team** (tým workloadu):
Tým zákazníka, který vlastní jeden nebo více workloadů.
_Avoid_: aplikační tým, vývojový tým

### GitHub

**GitHub App installation token** (instalační token GitHub App):
Přihlašovací údaj reprezentující instalaci GitHub App, nikoli uživatelský účet. Jeho oprávnění vycházejí z oprávnění App a rozsahu její instalace.
_Avoid_: admin token, servisní PAT

**Platform organization** (organizace platformy):
Organizace, ve které platformní tým spravuje instanci. Týmy workloadů do ní nemají přístup.
_Avoid_: admin organizace

**Actions organization** (organizace akcí):
Organizace se schválenými vendorovanými akcemi pro workflow instance.
_Avoid_: mirror akcí

**Workload organization** (organizace workloadů):
Organizace s repozitáři workloadů.
_Avoid_: vývojová organizace

### Azure

**Sovereign Landing Zone** (SLZ):
Landing zone podle CAF s politikami pro suverenitu dat. Platforma podporuje jen tuto architekturu.
_Avoid_: ALZ, landing zone bez upřesnění

**Shared application landing zone** (sdílená aplikační landing zone):
Aplikační landing zone, kterou spravuje platformní tým a ve které běží sdílené služby pro více workloadů.
_Avoid_: sdílený cluster, runtime

### Workloady

**Workload** (workload):
Aplikace, kterou vlastní jeden tým workloadu a kterou platforma onboarduje a chrání.
_Avoid_: aplikace, projekt
