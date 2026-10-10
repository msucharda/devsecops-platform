# Moduly se nasazují jako joby vygenerovaného workflow

CI zdrojového repozitáře vygeneruje z manifestů modulů workflow nasazení, ve kterém má každý modul vlastní job. Závislosti mezi joby (`needs`) odpovídají předpokladům a joby nevybraných modulů se přeskočí. Každý job spustí PowerShell 7 runner pro jeden modul ve vlastním environmentu. Výstupy modulu jdou do artifactu a závislý modul je dostane jako proměnné. Každý modul tak má vlastní environment se schválením a secrets a jeho identita čte jen svůj state.

## Considered Options

- Terragrunt. Zamítnuto: Další nástroj k vendorování a druhá syntaxe předpokladů vedle manifestu modulu.
- Jeden job pro všechny moduly. Zamítnuto: Environment patří jobu, takže moduly by nemohly mít vlastní schválení a secrets.
- `terraform_remote_state`. Zamítnuto: Modul by potřeboval čtení celého state předpokladu včetně citlivých hodnot.

## Consequences

- Výstupy modulu nesmí obsahovat citlivé hodnoty, protože jdou do artifactu.
- Autorizovaný běh planu spustí plan všech vybraných modulů, aby závislé moduly dostaly aktuální výstupy. PR bez oprávnění k přihlašovacím údajům má neprovedený cloudový plan podle ADR 0016.
- Modul `enterprise-baseline` má podle ADR 0016 samostatný plan job rulesetů s odděleným environmentem a credentialem. Výjimka s oprávněním k zápisu nesmí rozšířit oprávnění ostatních plan jobů; výběr modulu a jeho předpoklady se vztahují i na tento job.
