# organizations

Modul vytvoří organizace akcí a workloadů a nastaví jejich ownery a přiřazení role security manager.

Předpoklady: `emu-identity`.

## Organizace a role

- Organizace mají názvy `{name}-actions` a `{name}-workloads`. Opakované použití názvů určuje ADR 0008.
- Organization owners patří jen do platformního týmu.
- Security tým má roli security manager ve všech třech organizacích instance. Pokud ověření nepotvrdí přiřazení enterprise týmu i dědění role na jeho členech, roli získá tým organizace propojený se stejnou skupinou Entra ID. Samotné úspěšné přiřazení HTTP 204 nestačí.
- Workload týmy mají nejvýše `Maintain` na svých repozitářích, ne repository `Admin`, organization owner ani organizační role pro změnu kontrol.

## Identita

GitHub API používá installation tokeny enterprise-owned Apps podle ADR 0016. Plan má jen potřebná oprávnění ke čtení; apply vytváří organizace přes podporované enterprise API a zajišťuje instalace Apps potřebných pro navazující moduly. Apps a credentials pro plan a apply se nesdílejí.

Manifest musí deklarovat skutečná oprávnění a cílové prostředky. Enterprise oprávnění se nesmí automaticky rozšířit na ostatní moduly. Dostupnost vytváření organizací, instalací Apps a přiřazení rolí na GHE.com je podmínka nasazení; implementace nesmí přejít na PAT.

Živé ověření C2 ze 13. 10. 2026 potvrdilo fallback s týmem organizace propojeným přes SCIM: token s `members: write` a `organization_custom_org_roles: read` přiřadil `security_manager`, uživatel zdědil roli nepřímo z přesného týmu a zůstal `member`, ne owner. U enterprise týmu API přijalo přiřazení, ale dědění se nepodařilo potvrdit. Podrobnosti a hranice důkazu jsou v [C2 runbooku](../../docs/reference-instance.md#c2-role-security-manager-pro-enterprise-tým-4).

## Teardown

Destroy odstraní organizace akcí a workloadů a přiřazení role security manager. Zachová enterprise, organizaci platformy a ruční enterprise předpoklady. Apps založené pro instanci odstraní až lokální odstranění bootstrapu, po skončení workflow, která je používají.
