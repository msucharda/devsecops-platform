# organizations

Modul vytvoří organizace akcí a workloadů a nastaví jejich ownery a přiřazení role security manager.

Předpoklady: `emu-identity`.

## Organizace a role

- Organizace mají názvy `{name}-actions` a `{name}-workloads`. Opakované použití názvů určuje ADR 0008.
- Organization owners patří jen do platformního týmu.
- Security tým má roli security manager ve všech třech organizacích instance. Pokud GitHub nepodporuje přiřazení enterprise týmu, roli získá tým organizace propojený se skupinou Entra ID.
- Workload týmy mají nejvýše `Maintain` na svých repozitářích, ne repository `Admin`, organization owner ani organizační role pro změnu kontrol.

## Identita

GitHub API používá installation tokeny enterprise-owned Apps podle ADR 0016. Plan má jen potřebná oprávnění ke čtení; apply vytváří organizace přes podporované enterprise API a zajišťuje instalace Apps potřebných pro navazující moduly. Apps a credentials pro plan a apply se nesdílejí.

Manifest musí deklarovat skutečná oprávnění a cílové prostředky. Enterprise oprávnění se nesmí automaticky rozšířit na ostatní moduly. Dostupnost vytváření organizací, instalací Apps a přiřazení rolí na GHE.com je podmínka nasazení; implementace nesmí přejít na PAT.

## Teardown

Destroy odstraní organizace akcí a workloadů a přiřazení role security manager. Zachová enterprise, organizaci platformy a ruční enterprise předpoklady. Apps založené pro instanci odstraní až lokální odstranění bootstrapu, po skončení workflow, která je používají.
