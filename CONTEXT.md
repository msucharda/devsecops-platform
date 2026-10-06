# DevSecOps Platform

Modulární vývojová platforma pro zákazníky s GHE.com a EMU: enterprise a organizace GitHubu, Sovereign Landing Zone v Azure a kontroly v dodávce softwaru.

Termíny jsou anglicky, protože je používá kód. Český ekvivalent v závorce používají materiály pro uživatele.

## Language

### Platforma

**Platform** (platforma):
Sada modulů, ze kterých zákazník sestaví vývojovou platformu od enterprise GitHubu a landing zone v Azure po kontroly v dodávce softwaru.
_Avoid_: řešení, akcelerátor

**Instance** (instance):
Jedno nasazení platformy: jeden enterprise EMU na GHE.com, jeden tenant Entra ID a jedna Sovereign Landing Zone. Instance obsahuje organizaci pro workloady a organizaci pro vendorované akce. Instance jde nasadit a odstranit jako celek.
_Avoid_: prostředí, deployment

**Module** (modul):
Jedna samostatně nasaditelná schopnost platformy, například baseline organizace, povinná workflow nebo povýšení image. Modul poskytuje jednu nebo více kontrol. Modul může vyžadovat jiné moduly jako předpoklad.
_Avoid_: akcelerátor, komponenta

**Control** (kontrola):
Mechanismus, který zachytí incident. Advisory control jen doporučuje, enforcing control vynucuje.
_Avoid_: guardrail, ochrana

**Customer** (zákazník):
Organizace, která nasadí instanci platformy do svého enterprise EMU na GHE.com a svého tenantu Entra ID.
_Avoid_: klient, tenant

**Vendoring** (vendoring):
Převzetí externího kódu do organizace zákazníka jako kopie po review, s pinovanou verzí a určeným vlastníkem. Platí pro akce, skilly i release platformy.
_Avoid_: mirror, import

### Azure

**Sovereign Landing Zone** (SLZ):
Landing zone podle CAF s politikami pro suverenitu dat. Platforma podporuje jen tuto architekturu.
_Avoid_: ALZ, landing zone bez upřesnění

**Shared application landing zone** (sdílená aplikační landing zone):
Aplikační landing zone, kterou spravuje platformní tým a ve které běží sdílené služby pro více workloadů.
_Avoid_: sdílený cluster, runtime

### Workloady

**Workload** (workload):
Aplikace jednoho týmu zákazníka, kterou platforma onboarduje a chrání.
_Avoid_: aplikace, projekt
