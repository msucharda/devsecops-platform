# Workflow instance volají GitHub API přes GitHub App installation tokeny

Workflow v repozitáři instance používají pro správu GitHubu jediný způsob autentizace: GitHub App installation tokeny (instalační tokeny GitHub App). Způsob autentizace sjednocujeme, identity ani oprávnění ne. Automatizované kontroly přesouváme na úroveň organizací tam, kde zachovají požadované vynucování proti týmům workloadů; nepodporované operace nepokrýváme dalším typem tokenu.

## Identity a oprávnění

- Apps vlastní enterprise instance. Spravuje je platformní tým a změny oprávnění schvaluje security tým přes PR.
- GitHub App identity mohou moduly sdílet jen při shodných oprávněních, prostředcích a fázi. Širší oprávnění vyžadují výslovně schválenou výjimku.
- Plan a apply nesdílejí přihlašovací údaje. Read-only plan nesmí dostat ani privátní klíč, kterým by mohl vydat token pro zápis. Dva klíče stejné App s oprávněními k zápisu tuto hranici nevytvoří.
- Identity Azure a Microsoft Graph zůstávají oddělené podle modulu a fáze podle ADR 0015.
- Lokální bootstrap může použít OAuth token spouštějícího člověka podle ADR 0005. První registrace Apps a vložení klíčů mohou být řízené ruční kroky bootstrapu; běžná workflow nevyžadují interaktivní přihlášení.

## Plan a výjimka rulesetů

Plan používá oprávnění ke čtení. GitHub App permission mapování ověřené 10. 10. 2026 pro organizační API uvádí:

| Operace | Organization Administration |
|---|---|
| Čtení code security configurations, jejich defaults a připojených repozitářů | `read` |
| Čtení Actions permissions a custom patterns | `read` |
| Změny těchto nastavení | `write` |
| Seznam organizačních rulesetů a detail lokálních organizačních rulesetů, včetně bypass aktérů | `write` |

Pro rulesety přijímáme výjimku: samostatný plan job smí použít `Organization Administration: write` pro dané organizace. Toto oprávnění umožňuje také změny Actions policy a code security configurations; nejde o token omezený na čtení rulesetů. Privátní klíč ani token tohoto jobu nesmějí dostat ostatní plan joby. Oddělení musí platit také při noční detekci driftu.

Seznam organizačních rulesetů může obsahovat zděděné enterprise rulesety. Organizační endpoint poskytuje úplný detail pouze pro lokální ruleset se `source_type: Organization` a `source` odpovídajícím cílové organizaci. Token issuer musí odmítnout chybějící, neznámou nebo neshodnou dvojici `source_type` a `source`. U zděděného rulesetu smí přijmout pouze `source_type: Enterprise` a deklarovaný enterprise jako `source`; počet těchto rulesetů musí vrátit a vypsat jako neověřený detail. Tento výsledek nedokazuje bypass konfiguraci zděděného enterprise rulesetu. Akceptace #11 ověří úplný detail lokálního rulesetu samostatným probe v G8.

PR plan běží automaticky jen pro PR oprávněných členů platformního týmu v repozitáři instance. Platí to i pro ruleset job s širšími oprávněními, bez dalšího schválení security týmem. Tím výslovně důvěřujeme těmto autorům i s pravomocí měnit organizační nastavení. PR z forků, od jiných autorů nebo vytvořené App nesmějí přihlašovací údaje automaticky získat. Autorizace musí předcházet předání přihlašovacích údajů a nesmí záviset na kontrole, kterou může neautorizovaný PR změnit.

PR importu vytvořený App nemá nárok na automatický cloudový plan. Po jeho review a merge proběhne plan z chráněné větve `main` před schváleným apply. Workflow musí neprovedený PR plan výslovně označit; nesmí ho vykázat jako úspěšné ověření.

Zápis issue driftu provede samostatný reporting job s installation tokenem omezeným na potřebný zápis v repozitáři instance. Běžný plan kvůli reportování nesmí získat oprávnění k zápisu.

Pravidla schválení apply neměníme: platformní tým schvaluje celý běh a apply modulu `enterprise-baseline` navíc schvaluje security tým.

## Hranice vynucování a ruční operace

- Organization owners patří jen do platformního týmu. Workload týmy mají nejvýše repository roli `Maintain`, ne `Admin`.
- Kontroly omezují workload týmy. Platformní tým v roli organization owner je důvěryhodný správce a může organizační kontroly změnit; jeho změny mají procházet PR a změny mimo workflow má zachytit drift.
- Code security configurations jsou organizační, vynucené a výchozí pro nové repozitáře. Organizační nastavení nenahrazuje enterprise vynucení proti organization ownerovi.
- Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné Manual prerequisites (ruční předpoklady) před bootstrapem. Patří sem enterprise politika private a internal forků, omezení repozitářů v EMU user namespaces a enterprise PAT politiky. Teardown je zachová.
- O omezení classic PAT pro uživatele zatím není rozhodnuto. Použití installation tokenů tuto politiku samo neurčuje.
- Nepodporovaná operace modulu je Manual step (ruční krok) s popsaným vlastníkem a omezením planu, driftu a teardownu. Například konfigurace enterprise audit-log streamu, pro kterou dokumentace uvádí classic PAT, nesmí do workflow zavést PAT.
- Enterprise-owned App nelze považovat za credential pro libovolný externí privátní zdroj release. Pokud zdroj není dostupný bez autentizace ani installation tokenem, import zůstane ruční; workflow nesmí přejít na osobní PAT nebo OAuth token.

## Klíče a ověření nasazení

- Privátní klíče jsou environment secrets v repozitáři instance, oddělené podle modulu a fáze. Sdílení je přípustné jen podle pravidel identity výše.
- Installation token expiruje po jedné hodině; workflow si nový vydá bez člověka. Privátní klíč sám neexpiruje.
- Platformní tým rotuje klíče nejpozději po 90 dnech a okamžitě při podezření na kompromitaci. Nejprve vloží a ověří nový klíč, potom odvolá starý; vede termín další rotace.
- Apps založené pro instanci patří mezi prostředky bootstrapu i při ruční registraci. Po skončení závislých workflow je odstraní lokální odstranění bootstrapu nebo výslovně deklarovaný ruční krok; ruční enterprise předpoklady tím nemění.
- Dostupnost enterprise-owned Apps, potřebných API, oprávnění a zvolené tokenové akce na GHE.com je podmínka nasazení. Veřejná dokumentace není důkazem dostupnosti na konkrétní referenční instanci.
- Chybějící oprávnění nebo nepodporované API musí způsobit srozumitelnou chybu nebo předem deklarovaný ruční krok. Implementace nesmí automaticky přejít na PAT, rozšířit oprávnění ani přejmenovat neprovedené ověření na úspěšný plan.

## Considered Options

- Classic PAT pro všechna workflow. Zamítnuto: například GET organizační Actions policy vyžaduje `admin:org`, takže by běžný plan získal pravomoc k zápisu.
- Kombinace App tokenů a PAT pro enterprise endpointy. Zamítnuto: provoz by měl více způsobů autentizace a uživatelskou identitu pro privilegované operace.
- Striktně read-only plan všech kontrol. Pro rulesety zamítnuto: úplné čtení bypass konfigurace vyžaduje write access. Výjimku omezujeme na samostatný job a přiznáváme její skutečný rozsah.

## Zdroje

- [GitHub App permission mapování](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps) a [server-to-server data pro GHEC](https://github.com/github/docs/blob/main/src/github-apps/data/ghec-2026-03-10/server-to-server-permissions.json).
- [Organizační rulesety](https://docs.github.com/en/rest/repos/rules#get-an-organization-repository-ruleset), [code security configurations](https://docs.github.com/en/rest/code-security/configurations) a [Actions permissions](https://docs.github.com/en/rest/actions/permissions).
- [Enterprise-owned Apps](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/creating-github-apps-for-your-enterprise) a [správa privátních klíčů](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps).
- [Enterprise repository policies](https://docs.github.com/en/enterprise-cloud@latest/admin/enforcing-policies/enforcing-policies-for-your-enterprise/enforcing-repository-management-policies-in-your-enterprise) a [konfigurace audit-log streamu](https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/audit-log#create-an-audit-log-streaming-configuration-for-an-enterprise).
