#!/usr/bin/env bash
set -euo pipefail

# seed the french cooklang recipes
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Thirteen recipes converted from their source pages by cook.md (the Cooklang import
# service) and checked against those pages: every one parses with the pinned CookCLI
# without a warning, and each ingredient is counted once so the shopping lists add up.
# Each file keeps a `source:` line pointing at the page it came from.
#
# The four HelloFresh recipes come from their Canadian site, so their ingredients were
# renamed to what the same things are called in a French supermarket (crème sure ->
# crème fraîche épaisse, lime -> citron vert, tortillas de farine -> tortillas de blé...)
# and the "tasse" measures converted to g/ml. Quantities are otherwise the source's own.
#
# config/aisle.conf sorts the shopping list by supermarket aisle instead of dumping
# everything under "other". It covers all 91 ingredients these recipes use
# (`cook doctor aisle` checks that); add a line when you add a recipe.
#
# Seeding only: from here on the collection belongs to the app, which writes to this
# folder itself. An existing file is never overwritten, so nothing you edit in the web
# UI can be clobbered by this script.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

recipes_dir="$DOCKERSTORAGEDIR/recipes"
mkdir -p "$recipes_dir/config"
chown "$PUID:$PGID" "$recipes_dir/config"

written=0
kept=0

write_file() {
    # $1 = path below the recipe folder, stdin = contents
    if [ -e "$recipes_dir/$1" ]; then
        cat > /dev/null
        kept=$((kept + 1))
        return
    fi
    cat > "$recipes_dir/$1"
    chown "$PUID:$PGID" "$recipes_dir/$1"
    written=$((written + 1))
}

write_file 'Bœuf bourguignon.cook' <<'COOK_EOF'
---
title: Bœuf bourguignon
description: 'Recette Boeuf bourguignon : la vraie recette : la meilleure recette rapide et facile : 4 personnes, 300 min de préparation. Notée 4.7/5 par 335 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20220707/133382_w1024h1024c1cx1396cy931cxt0cyt162cxb2162cyb1386.jpg
time required: 5 hours
tags: 'Boeuf bourguignon : la vraie recette, daube, bourguignon, bourguignon, oignon, carotte, bouquet garni, vin rouge, beurre, sel, poivre, Facile, Moyen'
nutrition:
  calories: 667 calories
  fat: 32.8 g
  saturated fat: 18 g
  carbohydrates: 17 g
  sugar: 12.9 g
  protein: 39 g
  fiber: 5.5 g
  sodium: 1.6 g
  serving size: 591.3 grams
author: Anonyme
prep time: 1 hour
servings: 4
diet: GlutenFree
course: Plat principal
cook time: 4 hours
source: https://www.marmiton.org/recettes/recette_boeuf-bourguignon-la-vraie-recette_18889.aspx
---

Détailler la viande @bourguignon{600%g} en cubes de 3 cm de côté, enlever les gros morceaux de gras. 

Couper @oignon{4}(diced) en morceaux. Le faire revenir dans une #poêle{} au @beurre{100%g}(melted). Une fois transparent, le verser dans une cocotte en fonte de préférence. 

Procéder de même avec la viande mais en plusieurs fois, jusqu'à ce que tous les morceaux soient cuits. Les ajouter au fur et à mesure dans la cocotte. Ne pas avoir peur d'ajouter du @beurre{} entre chaque fournée. 

Quand toute la viande est dans la cocotte, déglacer la poêle avec de l'eau ou du vin et faire bouillir en raclant pour récupérer le suc. Saler avec @sel{} et poivrer avec @poivre{}. Ajouter au reste. 

Recouvrir le tout avec une partie du @vin rouge assez bon{} et faire mijoter quelques heures avec @bouquet garni{} et @carottes{4}(en rondelles). 

Le lendemain, faire mijoter au moins ~{120%minutes} en plusieurs fois, ajouter du @vin rouge assez bon{} ou de l'eau si nécessaire.
COOK_EOF

write_file 'Chili au bœuf.cook' <<'COOK_EOF'
---
title: Chili au bœuf
description: Grâce à ce chili modernisé, passez plus de temps à profiter de la vie et moins de temps dans la cuisine! Le chili au bœuf de ce soir déborde d’épices mexicaines, de légumes parfumés et de haricots copieux. Une touche de crème sure et de cheddar assure une finale pleine de fraîcheur!
image: https://img.hellofresh.com/f_auto,fl_lossy,h_640,q_auto,w_1200/hellofresh_s3/image/chili-au-boeuf-45b67e8b.jpg
servings: 2
cuisine: Mexicaine
nutrition:
  calories: 780 kcal
  fat: 37 g
  saturated fat: 13 g
  carbohydrates: 65 g
  sugar: 13 g
  protein: 46 g
  fiber: 18 g
  sodium: 1440 mg
  serving size: 741
source: https://www.hellofresh.ca/recipes/game-day-beef-chili-5c2e7611e3f33911c2166272?locale=fr-CA
author: HelloFresh
time required: 30 minutes
course: Plat principal
---

Avant de commencer, préchauffer le four à la fonction Griller (température élevée). Laver et sécher tous les fruits et légumes. 

Évider le @poivron vert{200%g}, puis le couper en morceaux de 1,25 cm (1⁄2 po). Égoutter et rincer les @haricots rouges{370%ml}. Peler, puis émincer ou presser l’@ail{9%g}.

Dans un petit bol, mélanger @huile{1%cs} et 1/4 c. à thé de l’ail. (REMARQUE : Consulter le guide pour la quantité d’ail.)

Faire chauffer une grande #casserole{} à feu moyen-élevé. Ajouter @huile{1/2%cs}, puis le @bœuf haché{250%g}. Faire cuire le bœuf de ~{4-5%minutes} en le défaisant en morceaux, jusqu’à ce qu’il perde sa couleur rosée. Égoutter soigneusement l’excès de gras et le jeter.

Ajouter dans la casserole les morceaux d’@oignon{56%g}(haché) et de poivron, et le reste de l’@ail. Faire cuire de ~{5-6%minutes} en remuant souvent, jusqu’à ce que les poivrons ramollissent. Ajouter @épices mexicaines{2%cs} et @concentré de tomates{2%cs}. Poursuivre la cuisson pendant ~{1%minute}, en remuant souvent, jusqu’à ce que les aliments dégagent leur arôme. Saler et poivrer avec @sel{} et @poivre{}.

Ajouter dans la casserole les @haricots rouges{}, les @tomates concassées{370%ml} et @eau{60%ml}. Mélanger, puis porter à ébullition à feu élevé. Baisser à feu moyen. Faire mijoter de ~{8-10%minutes} en remuant à l’occasion, jusqu’à ce que le chili épaississe légèrement. Saler et poivrer.

Pendant que le chili mijote, couper les @pain ciabatta{2} en deux, puis badigeonner l’intérieur de chaque tranche d’huile à l’ail. Disposer les tranches sur une plaque à cuisson, côté coupé vers le haut. Faire griller au centre du four de ~{3-4%minutes} jusqu’à ce que les tranches de pain soient légèrement dorées. (CONSEIL : Surveiller les tranches de pain pour ne pas les brûler!)

Répartir le chili dans les bols. Parsemer de @cheddar{25%g}(râpé) et couronner de @crème fraîche épaisse{3%cs}. Servir les pains ciabatta à l’ail en accompagnement.
COOK_EOF

write_file Croque-monsieur.cook <<'COOK_EOF'
---
title: Croque-monsieur
description: 'Recette Croque-monsieur : la meilleure recette rapide et facile : 4 personnes, 15 min de préparation. Notée 4.6/5 par 107 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20170112/28965_w1024h1024c1cx1500cy1000.jpg
author: pattye
time required: 15 minutes
nutrition:
  calories: 626 calories
  fat: 37 g
  saturated fat: 22.3 g
  carbohydrates: 22 g
  sugar: 2.9 g
  protein: 51 g
  fiber: 1.8 g
  sodium: 4.9 g
  serving size: 245.3 grams
servings: 4
source: https://www.marmiton.org/recettes/recette_croque-monsieur_19208.aspx
prep time: 10 minutes
tags: Croque-monsieur, croque-monsieur, pain de mie, beurre tendre, jambon, toastinette, gruyère râpé, lait, muscade, poivre, sel, Très facile, Bon marché, rapide
course: Plat principal
cook time: 5 minutes
---

Beurrez les @pain de mie{8}(tranches) sur une seule face. Posez @toastinette{1}(tranche) sur chaque tranche de pain de mie. Posez @jambon{1}(tranche) plié en deux sur 4 tranches de pain de mie. Recouvrez avec les autres tartines (face non beurrée au dessus).

Dans un bol, mélangez @gruyère{100%g} avec @lait{4%cuillères à soupe}, @sel{}, @poivre{} et @muscade{1%pincée}. 

Répartissez le mélange sur les croque-monsieur. 

Placez sur une #plaque au four{} sous le grill pendant ~{10%minutes}.
COOK_EOF

write_file 'Gratin dauphinois.cook' <<'COOK_EOF'
---
title: Gratin dauphinois
description: 'Recette Gratin Dauphinois : la meilleure recette rapide et facile : 6 personnes, 85 min de préparation. Notée 4.7/5 par 938 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20201217/116563_w1024h1024c1cx1116cy671cxt0cyt0cxb2232cyb1342.jpg
cook time: 1 hour
source: https://www.marmiton.org/recettes/recette_gratin-dauphinois_13809.aspx
servings: 6
diet: Vegetarian, GlutenFree
nutrition:
  calories: 552.8 calories
  fat: 32.5 g
  saturated fat: 22 g
  carbohydrates: 47.8 g
  sugar: 3 g
  protein: 13.5 g
  fiber: 5 g
  sodium: 1 g
  serving size: 488.5 grams
course: Plat principal
tags: Gratin Dauphinois, gratin dauphinois, pomme de terre, ail, crème, beurre, lait, muscade, sel, poivre, Facile, Bon marché
time required: 1 hour 25 minutes
prep time: 25 minutes
author: Anonyme
---

Eplucher, laver et couper @pommes de terre{1.5%kg}(en rondelles fines) (NB : ne pas les laver APRES les avoir coupées, car l'amidon est nécessaire à une consistance correcte).

Hacher @ail{2%gousses}(très finement).

Porter à ébullition dans une #casserole{} le @lait{1%l}, l'ail, @sel{}, @poivre{}, et @muscade{} puis y plonger les pommes de terre et laisser cuire ~{10-15%minutes}, selon leur fermeté.

Préchauffer le four à 180°C (thermostat 6) et beurrer un plat à gratin à l'aide d'une feuille de papier essuie-tout.

Placer les pommes de terre égouttées dans le plat. Les recouvrir de @crème{30%cl}, puis disposer des petites noix de @beurre{100%g} sur le dessus.

Enfourner pour ~{50-60%minutes} de cuisson.

Utiliser le lait restant de la cuisson des pommes de terre pour faire une soupe ou une purée dans la foulée.
COOK_EOF

write_file 'Linguines au bacon.cook' <<'COOK_EOF'
---
title: Linguines au bacon, sauce tomate crémeuse
description: Qui n’aime pas la sauce Alfredo? Avec celle-ci, vous verrez la vie en ROSE! Ce délicieux plat de linguines est surtout composé de tomates cerises douces. La sauce est rehaussée avec du bacon et du maïs et un soupçon d’oignons frits. Vous aurez le goût de lécher l’assiette après avoir tout dévoré!
image: https://img.hellofresh.com/f_auto,fl_lossy,h_640,q_auto,w_1200/hellofresh_s3/image/linguines-au-bacon-dans-une-sauce-tomate-cremeuse-ff90f16d.jpg
source: https://www.hellofresh.ca/recipes/linguines-au-poulet-et-au-bacon-dans-une-sauce-tomate-cremeuse-684069805a41964b9c034f2f?locale=fr-CA
author: HelloFresh
servings: 2
course: Plat principal
time required: 25 minutes
cuisine: Italienne
nutrition:
  calories: 1020 kcal
  fat: 61 g
  saturated fat: 31 g
  carbohydrates: 92 g
  sugar: 8 g
  protein: 26 g
  fiber: 8 g
  sodium: 840 mg
  serving size: 381
---

Avant de commencer, ajouter dans une grande casserole #casserole{} 10 tasses d’eau et @sel{2%cc} (les mêmes qtés pour 4 pers.). Couvrir et porter à ébullition à feu élevé. Laver et sécher tous les fruits et légumes. 

Ajouter @linguines{170%g} à l’eau bouillante. Cuire ~{10-12%minutes}, en remuant à l’occasion, jusqu’à ce que les pâtes soient tendres. Réserver @eau de cuisson{125%ml}, puis égoutter les linguines et les remettre dans la même casserole, hors du feu.

Entre-temps, recouvrir une assiette d’essuie-tout. Trancher @bacon{100%g} sur la largeur en lanières de 1,25 cm (1⁄2 po). (CONSEIL : Utiliser des ciseaux de cuisine pour couper le bacon plus facilement.) Chauffer une grande poêle antiadhésive #poêle{} à feu moyen-élevé. Ajouter le bacon. Cuire ~{5-7%minutes}, en remuant à l’occasion, jusqu’à ce qu’il soit croustillant**. (CONSEIL : Réduire à feu moyen si le bacon dore trop rapidement.) Retirer la poêle du feu. À l’aide d’une cuillère à rainures, transférer le bacon dans l’assiette recouverte d’essuie-tout. Réserver. Laisser l’excédent de gras de bacon dans la poêle. 

Entre-temps, égoutter @maïs doux{113%g}. Couper @tomates cerises{170%g} en deux.

Chauffer la poêle contenant le gras de bacon à feu moyen. Ajouter les tomates et le maïs. Saler et poivrer, puis cuire à couvert ~{3-4%minutes}, en remuant à l’occasion, jusqu’à ce que les tomates ramollissent.

Dans la poêle contenant les légumes, ajouter @purée d’ail{1%cs} et @épices pour sauce crémeuse{1%cs}. Cuire pendant ~{30%seconds}, en remuant souvent, jusqu’à ce que les légumes soient enrobés. Ajouter @crème{113%ml} et @eau{60%ml}. Poivrer. Porter à ébullition à feu élevé. Réduire à feu moyen et cuire ~{2-3%minutes}, en remuant souvent, jusqu’à ce que la sauce épaississe légèrement. Retirer la poêle du feu.

Dans la casserole contenant les linguines, ajouter @pousses d'épinards{56%g}, la sauce, la moitié du bacon, @parmesan{25%g} et @beurre{1%cs} (non salé). Saler et poivrer, au goût. Remuer pendant ~{1%minute}, jusqu’à ce que les épinards tombent. (CONSEIL : Pour une consistance plus légère, ajouter de l’eau de cuisson réservée, de 1 à 2 c. à soupe à la fois, si désiré.) Répartir les linguines dans les bols. Parsemer d’@oignons frits{28%g}, du reste du bacon et du reste du parmesan.
COOK_EOF

write_file 'Orzo à la dinde et pesto.cook' <<'COOK_EOF'
---
title: Orzo à la dinde et pesto de tomates séchées
description: 'Ingrédients : Dinde hachée • Orzo (semoule de blé dur, niacine, sulfate de fer, mononitrate de thiamine, riboflavine, acide folique) (blé) • Poivron • Crème 35% (crème, lait, dextrose, gel de cellulose, carraghénane, mono et diglycérides, gomme de cellulose, polysorbate 80, citrate de sodium, phosphate disodique) (lait) • Citron • Pesto de tomates séchées (tomates séchées au soleil, eau, huile de soya, huile de canola & huile d''olive extra vierge, tomates, ail, parmesan (lait, culture bactérienne, sel, lipase, chlorure de calcium, enzyme microbienne, cellulose en poudre), feuilles de basilic, sel, sucre, herbes, épices, vinaigre, acide citrique, gomme xanthane, sorbate de potassium) (lait) • Épinards • Sauce tomate (eau, pâte de tomate, amidon de maïs modifié, huile de soja, acide phosphorique, gomme xanthane, sorbate de potassium, benzoate de sodium) • Parmesan (lait pasteurisé, substances laitières modifiées, eau, amidon de maïs et/ou amidon de pomme de terre modifiés, fromage (lait, culture bactérienne, sel, enzyme microbienne, lipase), sel, acide citrique, phosphate de sodium, acide lactique, arôme, citrate de sodium, sorbate de potassium, colorant caramel, bêta-carotène, mélange antiagglomérant (fécule de pomme de terre, amidon de maïs, dextrose, sulfate de calcium, cellulose, natamycine, enzyme)) (lait) • Concentré de bouillon de poulet (sucres (maltodextrine, sucre), bouillon de poulet, graisse de poulet, arôme de poulet (bouillon de poulet, sel, arôme, eau, acide glutamique, gras de poulet, poudre de poulet, gomme xanthane, huile de tournesol biologique), sel, extrait de levure, gomme xanthane, arôme naturel) • Ail • Mélange d''épices aux herbes italiennes (sel, oignon déshydraté, ail déshydraté, herbes, sucre, oignon en poudre, ail en poudre, huile de canola, dioxyde de silicium) (sulfites).'
image: https://img.hellofresh.com/f_auto,fl_lossy,h_640,q_auto,w_1200/hellofresh_s3/image/033b6361-573c-511d-9c39-0e26bd67a058-8843ce48.jpg
source: https://www.hellofresh.ca/recipes/tout-en-un-orzo-a-la-dinde-et-au-pesto-de-tomates-a-lail-687a6385c30d33981f9adda9
cuisine: Italienne
nutrition:
  calories: 980 kcal
  fat: 52 g
  saturated fat: 22 g
  carbohydrates: 81 g
  sugar: 9 g
  protein: 44 g
  fiber: 7 g
  sodium: 1500 mg
  serving size: 479
course: Plat principal
servings: 2
author: HelloFresh
time required: 20 minutes
---

Avant de commencer, préchauffer une grande #casserole{} à feu moyen.

Laver et sécher tous les fruits et légumes. Évider, puis couper le @poivron{1}(en morceaux de 0,5 cm). Hacher finement ou presser les @gousses d'ail{2}. Presser la moitié du @citron{1} et couper le reste en quartiers.

Dans la casserole, ajouter @huile{1%cs}, puis la @dinde hachée{250%g}. Cuire de ~{3-4%minutes}, en défaisant la dinde en morceaux, jusqu’à ce qu’elle perde sa couleur rosée. Saler @sel{} et poivrer @poivre{}.

Ajouter l’ail, le poivron et le @herbes italiennes{5%g}. Poursuivre la cuisson pendant ~{2%minutes}, en remuant souvent, jusqu’à ce que les poivrons soient légèrement croquants.

Ajouter l’@orzo{170%g} à la casserole. Cuire pendant ~{1%minute}, en remuant souvent.

Ajouter la @concentré de tomates{2%cs}, le @bouillon de volaille{}, le @pesto de tomates séchées{60%g}, la @crème{113%ml} et @eau{500%ml}. Porter à légère ébullition. Réduire à feu moyen.

Laisser mijoter à couvert pendant ~{10-12%minutes}, en remuant souvent, jusqu’à ce que presque tout le liquide ait été absorbé et que l’orzo soit tendre.

Lorsque l’orzo sera cuit, le retirer du feu. Dans la casserole, ajouter @beurre{1%cs}, la moitié du @parmesan{25%g}, le jus de citron et les @pousses d'épinards{56%g}. Saler et poivrer, puis bien mélanger.

Répartir le mélange d’orzo à la dinde dans les bols. Parsemer du reste du parmesan. Arroser du jus d’un quartier de citron.
COOK_EOF

write_file 'Poulet au riz à la moutarde.cook' <<'COOK_EOF'
---
title: Poulet au riz à la moutarde
description: 'Recette Poulet au riz sauce moutarde et vin blanc : la meilleure recette rapide et facile : 2 personnes, 30 min de préparation. Notée 4.5/5 par 6 membres Marmiton.'
image: https://www.marmiton.org/assets/images/default-recipe-picture_80x80-6PRRwF3.jpg
course: Plat principal
servings: 2
time required: 30 minutes
cook time: 15 minutes
source: https://www.marmiton.org/recettes/recette_poulet-au-riz-sauce-moutarde-et-vin-blanc_64953.aspx
nutrition:
  calories: 444 calories
  fat: 10.2 g
  saturated fat: 1.7 g
  carbohydrates: 30 g
  sugar: 7.4 g
  protein: 48 g
  fiber: 4 g
  sodium: 3.7 g
  serving size: 477.5 grams
diet: GlutenFree, LowLactose
author: laura_13695294
tags: Poulet au riz sauce moutarde et vin blanc, plat de riz, escalope de poulet, poivron, oignon, riz, vin blanc, moutarde, poivre, sel, huile d'olive, Très facile, Bon marché
prep time: 15 minutes
---

Faire cuire @riz{125%g} dans un grand volume d'eau bouillante salée pendant ~{10%minutes}.

Pendant ce temps, couper les @escalopes de poulet{2}(en lamelles) et les faire dorer dans une #poêle{}.

Dans un #wok{}, faire cuire @poivron{1}(en lamelles très fines) et @oignon{1}(en lamelles très fines).

Quand le tout prend une jolie couleur caramélisée, mettre @vin blanc{15%cl}.

Laisser revenir ~{5%minutes} et enfin verser @moutarde{2%grandes cuillères à soupe}.

Ajoutez au wok le poulet.

Quand le riz est cuit, l'ajouter à la préparation, verser @huile d'olive{}(au goût), saler @sel{} et poivrer @poivre{}.

Servir chaud dans un joli service et déguster. Bon appétit !
COOK_EOF

write_file 'Pâtes cajun au poulet.cook' <<'COOK_EOF'
---
title: Pâtes cajun au poulet
source: https://www.tiktok.com/@panaceapalm/video/7213411161142889734
author: Panacea Palm (@panaceapalm)
servings: 5
description: Pâtes crémeuses aux épices cajun, riches en protéines. Recette traduite de l'anglais depuis la vidéo d'origine.
---

Faire cuire @penne{450%g} dans une grande quantité d'eau salée, en réservant @eau de cuisson{100%ml} pour plus tard.

Couper @blancs de poulet{700%g} en dés, les mettre dans un bol et les assaisonner avec @épices cajun{1.5%cs}. Verser ensuite @huile d'olive{25%ml} et bien mélanger pour les enrober.

Faire cuire le poulet en plusieurs fois (pour ne pas surcharger la poêle) à feu moyen-vif, jusqu'à ce qu'il soit doré et croustillant. Réserver le poulet, puis dans la même poêle ajouter @oignon{1}(émincé) et @ail{1}(haché) et remuer ~{1-2%minutes} jusqu'à ce qu'ils soient tendres.

Ajouter @sauce tomate{500%g} et @fromage à la crème{200%g}. Une fois le fromage fondu, ajouter @épinards{150%g} et les laisser tomber. Remettre le poulet en remuant bien pour l'enrober, puis ajouter @mozzarella{200%g} et l'eau de cuisson réservée, et remuer pour faire fondre le fromage.

Ajouter les pâtes cuites et mélanger, puis parsemer de @flocons de piment{} et de @poivre noir{}. Répartir en 5 portions.
COOK_EOF

write_file 'Pâtes crémeuses au bœuf et à l'"'"'ail.cook' <<'COOK_EOF'
---
title: 'Pâtes crémeuses au bœuf et à l''ail'
source: https://www.tiktok.com/@panaceapalm/video/7358524883141233952
author: Panacea Palm (@panaceapalm)
servings: 4
description: Pâtes au bœuf haché dans une sauce tomate crémeuse à l'ail. Recette traduite de l'anglais depuis la vidéo d'origine.
---

Porter à ébullition une grande casserole d'@eau{}(salée) et ajouter @pâtes{300%g}(conchiglie). Cuire al dente, puis égoutter.

Dans une #grande casserole{}, chauffer @huile{1%cs} à feu moyen. Ajouter @oignon{1}(haché) et @ail{4%gousses}(émincées). Faire revenir jusqu'à ce qu'ils soient tendres.

Ajouter @boeuf haché{800%g} et cuire jusqu'à ce qu'il soit bien coloré. Assaisonner avec @ail en poudre{}, @oignon en poudre{}, @paprika fumé{}, @sel{} et @poivre noir moulu{}, au goût.

Ajouter @sauce tomate{400%ml}, @bouillon de boeuf{200%ml} et @crème entière{200%ml}. Bien mélanger et porter à frémissement.

Parsemer d'@herbes italiennes{1%cc} et remuer jusqu'à homogénéité.

Mélanger les pâtes cuites à la sauce, en remuant jusqu'à obtenir une texture crémeuse.

Servir garni de @pecorino ou parmesan râpé{4%cs} et de @basilic{}(haché).

> Se conserve au réfrigérateur jusqu'à 5 jours en boîtes de meal prep. Au moment de manger, réchauffer au micro-ondes ~{2-3%minutes} et remuer jusqu'à ce que ce soit crémeux.
COOK_EOF

write_file 'Quesadillas au porc.cook' <<'COOK_EOF'
---
title: Quesadillas au porc et salsa maison
description: Ces quesadillas rapides et faciles à préparer débordent de porc, de poivrons, mais surtout, de fromage fondu bien collant! Trempez vos quesadillas dorées dans une rafraîchissante crème au citron vert, une salsa éclatante ou dans les deux. Où que vous alliez, dégustez ce souper idéal (presque littéralement) à toutes les sauces.
image: https://img.hellofresh.com/f_auto,fl_lossy,h_640,q_auto,w_1200/hellofresh_s3/image/quesadillas-fromagees-au-porc-f7b8ab48.jpg
nutrition:
  calories: 850 kcal
  fat: 48 g
  saturated fat: 21 g
  carbohydrates: 58 g
  sugar: 10 g
  protein: 46 g
  fiber: 6 g
  sodium: 1150 mg
  serving size: 478
servings: 2
source: https://www.hellofresh.ca/recipes/quesadillas-fromagees-au-porc-646c217d464301b6130efb58?locale=fr-CA
author: HelloFresh
course: Plat principal
time required: 35 minutes
cuisine: Americaine
---

Avant de commencer, laver et sécher tous les fruits et légumes. Évider, puis couper @poivron{160%g}(en morceaux de 1,25 cm). Émincer @oignons nouveaux{1}(finement). Peler @oignon rouge{56%g}, puis couper la moitié en morceaux de 0,5 cm. Zester, puis presser la moitié de @citron vert{1}(le citron vert entier pour 4 pers.). Couper le reste du citron vert en quartiers. Couper @tomate{80%g}(en morceaux de 0,5 cm).

Dans un bol moyen, ajouter la tomate, les oignons verts, la moitié du poivron, la moitié du jus de citron vert et @huile{2%cc}. Saler @sel{} et poivrer @poivre{}, puis bien mélanger.

Dans un petit bol, ajouter @crème fraîche épaisse{3%cs}, 1/2 c. à thé de zeste de citron vert, 1 c. à thé de jus de citron vert et @sucre{1/4%cc}. Saler @sel{} et poivrer @poivre{}, puis bien mélanger.

Chauffer une grande #poêle antiadhésive{} à feu moyen-élevé. Ajouter @huile{2%cc}, puis @porc haché{250%g}, l’oignon rouge et le reste du poivron. Cuire pendant ~{4-6%minutes}, en défaisant le porc en morceaux, jusqu’à ce qu’il perde sa couleur rosée. Égoutter l’excédent de gras avec précaution et le jeter. Saupoudrer le porc d’@épices mexicaines{1%cs}. Cuire pendant ~{30%seconds}, en remuant souvent, jusqu’à ce que les aliments dégagent leur arôme. Retirer du feu, puis transférer le mélange de porc dans un grand bol. Ajouter @mozzarella{75%g}(râpée), puis saler @sel{} et poivrer @poivre{}, au goût. Remuer jusqu’à ce que le tout soit combiné.

Rincer et essuyer la poêle avec précaution. Disposer les @tortillas de blé{6}(sur une surface propre). Étendre uniformément la garniture de porc sur la moitié de chaque tortilla. Replier les tortillas sur elles-mêmes par-dessus le mélange. Chauffer la même poêle à feu moyen-élevé. Ajouter 3 quesadillas à la poêle sèche. Cuire pendant ~{1-2%minutes} par côté, jusqu’à ce que les quesadillas soient dorées. Transférer dans une assiette. Réduire à feu moyen et répéter avec le reste des quesadillas.

Couper les quesadillas en quartiers. Répartir les quesadillas dans les assiettes. Servir la crème au citron vert et la salsa comme trempette. Arroser du jus d’un quartier de citron vert, si désiré.
COOK_EOF

write_file 'Quiche lorraine.cook' <<'COOK_EOF'
---
title: Quiche lorraine
description: 'Recette Quiche lorraine maison : la meilleure recette rapide et facile : 4 personnes, 55 min de préparation. Notée 4.7/5 par 1228 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20161128/28118_w1024h1024c1cx845cy3505cxt0cyt1385cxb3451cyb5177.jpg
author: Fée Clochette
source: https://www.marmiton.org/recettes/recette_quiche-lorraine_30283.aspx
servings: 4
prep time: 10 minutes
time required: 55 minutes
nutrition:
  calories: 623.9 calories
  fat: 48 g
  saturated fat: 25.5 g
  carbohydrates: 26.7 g
  sugar: 3.6 g
  protein: 20.2 g
  fiber: 1.7 g
  sodium: 3.4 g
  serving size: 256.3 grams
tags: Quiche lorraine maison, quiche lorraine, pâte brisée, lardons, beurre, oeuf, crème fraîche, lait, muscade, sel, poivre, Très facile, Bon marché
course: Plat principal
cook time: 45 minutes
---

Préchauffer le four à 180°C (thermostat 6).

Etaler la pâte @pâtes brisées{200%g} dans un #moule{},

la piquer à la fourchette. Parsemer de copeaux de @beurre{30%g}.

Faire rissoler les @lardons{200%g} à la poêle puis les éponger avec une feuille d'essuie-tout.

Battre les @oeufs{3}, la @crème fraîche{20%cl} et le @lait{20%cl}.

Ajouter les lardons.

Assaisonner de @sel{}, de @poivre{} et de @muscade{}.

Verser sur la pâte.

Cuire ~{45-50%minutes}.

C'est prêt

Déguster
COOK_EOF

write_file 'Spaghettis bolognaise.cook' <<'COOK_EOF'
---
title: Spaghettis bolognaise
description: 'Recette Incontournable sauce bolognaise pour spaghetti  : la meilleure recette rapide et facile : 10 personnes, 220 min de préparation. Notée 4.3/5 par 3 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20160317/40983_w1024h1024c1cx2016cy1339.jpg
servings: 10
nutrition:
  calories: 91 calories
  fat: 6.5 g
  saturated fat: 4.4 g
  carbohydrates: 5.1 g
  sugar: 4.6 g
  protein: 2 g
  fiber: 2 g
  sodium: 0 g
  serving size: 145 grams
course: Sauce
time required: 3 hours 40 minutes
prep time: 40 minutes
cook time: 3 hours
source: https://www.marmiton.org/recettes/recette_incontournable-sauce-bolognaise-pour-spaghetti_35980.aspx
author: Anonyme
tags: Incontournable sauce bolognaise pour spaghetti , Autres sauces, poivron vert, poivron rouge, poivron, céleri, oignon, champignon frais, tomate, concentré de tomates, sauce tomate, chili, viande hachée, crème, Très facile, Moyen
diet: GlutenFree
---

Coupez @poivron vert{1}(diced), @poivron rouge{1}(diced), @poivron orange{1}(diced), @céleri{2}(diced), @oignon{1}(diced) et @champignon frais{1}(sliced) et mettez le tout dans une très grande #marmite{}.

Faites cuire @viande hachée{3.5%kg} et mettez-la dans la même marmite lorsqu'elle est cuite.

Ajoutez ensuite @tomates étuvées{480%g}(coupées en dés, assaisonnées à l'italienne), @concentré de tomates{1}(grosse boîte), @sauce tomate{1}(grosse boîte) et @chili{1}(bouteille avec gros morceaux) à votre préparation.

Laissez mijoter à feu moyen d'abord, puis baissez graduellement lorsque la sauce bout, pendant ~{180%minutes} ou plus.

Servez et récoltez les compliments ! Vous verrez, le secret est vraiment dans la sauce !

> Ce plat est parfait pour les grandes occasions et les repas en famille.
COOK_EOF

write_file 'Spaghettis carbonara.cook' <<'COOK_EOF'
---
title: Spaghettis carbonara
description: 'Recette Spaghettis carbonara : la recette italienne sans crème ! : la meilleure recette rapide et facile : 4 personne(s), 15 min de préparation. Notée 4.7/5 par 30 membres Marmiton.'
image: https://assets.afcdn.com/recipe/20200121/106797_w1024h1024c1cx1944cy1296cxt0cyt0cxb3887cyb2592.jpg
course: Plat principal
author: Anonyme
tags: 'Spaghettis carbonara : la recette italienne sans crème !, pâtes, riz, semoule, pâtes, pecorino, poitrine fumée, oeuf, poivre, Très facile, Bon marché, rapide'
cook time: 10 minutes
nutrition:
  calories: 964 calories
  fat: 41.6 g
  saturated fat: 19.6 g
  carbohydrates: 81 g
  sugar: 4.1 g
  protein: 63 g
  fiber: 4.8 g
  sodium: 2.1 g
  serving size: 360.3 grams
prep time: 5 minutes
time required: 15 minutes
servings: 4
source: https://www.marmiton.org/recettes/recette_spaghettis-carbonara-la-recette-italienne-sans-creme_382805.aspx
---

Préparer la sauce de la carbonara: battre les @oeufs{4}(jaunes) avec environ @pecorino{150%g} râpé et @poivre{} jusqu’à obtenir une pâte homogène.

Découper la @poitrine fumée ou @guanciale{300%g} en gros dés.

Les faire revenir dans une #poêle{} bien chaude jusqu’à ce que les dés soient légèrement roussis.

Faire cuire les @pâtes{600%g} dans une eau non salée (la poitrine est déjà très salée).

Ajouter quelques pâtes chaudes à la sauce et mélanger (cela va réchauffer un peu la sauce avant de l’ajouter aux pâtes).

Mélanger le reste des pâtes avec le guanciale sans jeter le gras (il va donner consistance et saveur à la sauce).

Ajouter la sauce de la carbonara et mélanger énergiquement pour obtenir une consistance homogène.

Ajouter un peu de pecorino sur votre plat de spaghettis, bomber le torse et déguster tant que c'est chaud !
COOK_EOF

write_file 'config/aisle.conf' <<'COOK_EOF'
[fruits et légumes]
ail | gousses d'ail
purée d’ail
oignon
oignon rouge
oignons nouveaux
poivron
poivron vert
poivron rouge
poivron orange
tomate
tomates cerises
carottes
céleri
champignon frais
pommes de terre
pousses d'épinards | épinards
basilic
citron
citron vert

[viandes et charcuterie]
blancs de poulet | escalopes de poulet
dinde hachée
boeuf haché | bœuf haché | viande hachée
bourguignon
porc haché
jambon
lardons
bacon
guanciale
poitrine

[crèmerie]
lait
beurre
crème
crème fraîche
crème fraîche épaisse
crème entière
oeufs
parmesan | pecorino ou parmesan râpé
pecorino
mozzarella
gruyère
cheddar
fromage à la crème
toastinette

[boulangerie]
pain de mie
pain ciabatta
tortillas de blé
pâtes brisées

[épicerie]
pâtes
linguines
penne
orzo
riz
sauce tomate
concentré de tomates
tomates concassées
tomates étuvées
haricots rouges
maïs doux
chili
pesto de tomates séchées
moutarde
huile
huile d'olive
bouillon de boeuf
bouillon de volaille
oignons frits
sucre

[épices et condiments]
sel
poivre | poivre noir | poivre noir moulu
muscade
paprika fumé
flocons de piment
ail en poudre
oignon en poudre
bouquet garni
herbes italiennes
épices cajun
épices mexicaines
épices pour sauce crémeuse

[cave]
vin blanc
vin rouge assez bon

[à la maison]
eau
eau de cuisson
COOK_EOF

echo "$recipes_dir: $written file(s) written, $kept already present."
