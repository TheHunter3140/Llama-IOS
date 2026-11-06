# Pal Llama-IOS IA local

Pal est une application iOS SwiftUI construite autour de `llama.cpp` et de modèles GGUF locaux.

## Fonctionnalités présentes dans cette version

- Inférence locale via llama.cpp.
- Sélection de GGUF dans l'app Fichiers avec signets de sécurité iOS : les gros modèles ne sont pas copiés dans le conteneur Pal.
- Chat persistant, génération en streaming, arrêt et régénération.
- Rendu Markdown natif de base et export de conversation en `.md`.
- Réglages d'échantillonnage, prompt système, thème, couleur, taille du texte et profils mémoire.
- Panneau de diagnostic : mémoire, thermique, batterie, vitesse et contexte.
- **Inspiré de PocketPal AI** : benchmark intégré (pp / tg / 1er token / RAM, dans le panneau jauge), modification du dernier message, régénération, métriques en direct, alerte « RAM juste » avant chargement d'un gros modèle.
- **Pal Skills** : compétences intégrées, création dans l'application, import de fichiers `.md` / `.txt`, activation et suppression.
- Les Skills actives sont ajoutées au prompt système avec une limite de taille pour contenir l'usage du contexte.
- **Pal Research** : recherche Web DuckDuckGo, affichage de titres/extraits/liens, ouverture des sources et insertion des résultats dans le champ de chat.
- Les résultats Web sont signalés au modèle comme contenu externe non fiable ; aucune instruction récupérée n'est exécutée.

## Skills : ce que signifie « apprendre »

Une Skill est un paquet d'instructions et de méthodes réutilisables. Elle oriente le modèle à chaque requête pertinente. **Elle ne modifie pas les poids du GGUF et n'effectue pas de fine-tuning.** Les connaissances importées ne deviennent pas automatiquement des faits vérifiés.

Exemples disponibles dans `Examples/Skills/` :
- `mathematiques-l1.md`
- `revue-code.md`

Pour ajouter une Skill, ouvre l'onglet étincelles dans Pal, puis crée une compétence ou importe un fichier texte/Markdown. Les compétences importées sont stockées dans les préférences locales de l'application. Une limite de 64 Ko est appliquée à l'import et le prompt transmis au modèle est plafonné.

## Recherche Web et confidentialité

- La recherche nécessite une connexion Internet.
- Les requêtes sont envoyées à DuckDuckGo par HTTPS. Elles ne sont pas envoyées au moteur llama.cpp local.
- Pal n'utilise pas de clé API ni de serveur personnel pour cette fonction.
- La page HTML de recherche peut évoluer ou limiter les requêtes ; dans ce cas, la recherche peut échouer et devra être adaptée.
- Vérifie les pages originales avant de te fier aux extraits. Les pages Web peuvent contenir des erreurs ou des instructions malveillantes.
- Une fois les résultats insérés dans le chat, la génération du résumé reste locale.

## Compilation cloud

1. Déposer tout le contenu du dépôt, y compris le dossier caché `.github/`, à la racine de GitHub.
2. Ouvrir **Actions** et lancer **Build Pal IPA (unsigned)**.
3. Télécharger l'artefact `Pal-ipa-unsigned`.
4. L'IPA produit est **non signé** : il faut le signer avec une méthode iOS autorisée avant installation.

Le workflow télécharge le XCFramework iOS llama.cpp depuis la dernière release llama.cpp qui en contient un, puis génère le projet avec XcodeGen et lance Xcode sur un runner macOS.

## Limites connues et prochaine étape

- La compilation Xcode réelle n'a pas été exécutée dans cet environnement ; seule l'analyse syntaxique Swift et la validation YAML ont été effectuées.
- La recherche DuckDuckGo repose sur l'analyse de sa page HTML : ce format peut changer, ce n'est pas une API contractuelle.
- La recherche ne télécharge pas et n'analyse pas automatiquement l'intégralité des pages ; elle fournit des extraits et des liens.
- Pas encore (prévu après un premier build réussi) : téléchargement depuis Hugging Face, plusieurs conversations, vision réelle.
- L'association `mmproj` est mémorisée, mais le pipeline vision n'est pas implémenté.
- Le rendu Markdown natif couvre le formatage courant ; tableaux complexes et blocs de code avec coloration nécessitent un moteur dédié.
- Les fichiers iCloud doivent être téléchargés localement pour une utilisation hors ligne.
- Les Skills consomment du contexte ; sur un iPhone XR, active seulement celles qui sont utiles.

## Plateforme

- Déploiement minimum déclaré : iOS 16.
- Bundle ID : `com.local.pal`.
- SwiftUI + llama.cpp.
