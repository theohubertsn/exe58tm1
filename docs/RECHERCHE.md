# Analyse 58TM1 / Office / RDS / FSLogix

Recherche effectuee le 2 novembre 2026. Contexte demande : connexion du compte Office dans Outlook, Word, etc., Windows Server/RDS et FSLogix, sans version precise ni code d'erreur complet.

## Conclusion exploitable

**La demarche la plus defendable est de remettre en etat l'authentification moderne dans la session affectee, puis d'investiguer la persistance FSLogix si le probleme revient.** C'est un choix technique progressif, pas un taux de reussite mesure. Le seul tag `58TM1` ne permet pas de prescrire un KB ou une purge universelle.

| Observation | Piste prioritaire | Action disponible / limite |
| --- | --- | --- |
| Un seul utilisateur sur un seul hote | Profil local, enregistrement Broker ou identite Office | Audit, RepairUser, puis reinitialisation ciblee si necessaire |
| Tous les utilisateurs du meme hote | Composants Windows, version Office, proxy, strategie ou SCA | Audit hote ; verifier strategie et versions avant de generaliser une purge |
| Reapparition au changement d'hote / apres nouvelle session | Conteneur FSLogix, stockage des identites liees a l'appareil, jointure et version des hotes | Comparer les audits de deux hotes ; examiner FSLogix. Aucun changement automatique de RoamIdentity |
| Office indique un echec d'activation | Droits de licence, SCA, cache de licence | Verifier l'eligibilite ; ConfigureHost ou ResetOfficeLicensing si justifie |
| Broker absent ou manifeste Windows manquant | Installation Windows / mode serveur / composants | Arret avant purge ; reparation Windows par maintenance appropriee |
| Meme compte refuse aussi sur le portail web | Compte, service Entra, MFA ou acces conditionnel possibles | Analyser les journaux Entra. Une purge locale ne corrige pas une decision serveur |

## Sources reellement consultees

Les sources Microsoft ci-dessous ont ete lues dans le depot public officiel [MicrosoftDocs/SupportArticles-docs](https://github.com/MicrosoftDocs/SupportArticles-docs), plutot que par Microsoft Learn dont l'acces etait bloque. Les pages evoluent ; verifier leur version au moment d'une intervention.

1. [Reset activation state for Microsoft 365 Apps for enterprise](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/Office/Client/activation/reset-activation-state.md), date de l'article : 27 mai 2025. Documente notamment les emplacements utilisateur `Microsoft\Office\Licenses`, `Microsoft\Office\16.0\Licensing`, les cles Office `Common\Identity` et `Common\Licensing`, et les scripts Microsoft de nettoyage. Le kit reprend **des sous-operations ciblees** ; il ne pretend pas reproduire le nettoyage complet Microsoft et ne retire pas les cles produit de l'hote.
2. [Unable to create an Outlook profile after a migration with Event 1098](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/Outlook/classic-outlook-for-windows/profiles-and-accounts/event-1098-and-cannot-create-new-profiles.md), KB 4499299, 30 janvier 2024. Microsoft decrit des donnees associees a un ancien SID et le dossier `Microsoft.AAD.BrokerPlugin...\AC\TokenBroker\Accounts`. **Cas documente : migration et SID change**, pas preuve que toute erreur 58TM1 vient de ce dossier. Cette reinitialisation reste facultative.
3. [Resolve issues in Exchange Online PowerShell module after WAM integration](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/Exchange/ExchangeOnline/administration/wam-integration-issues.md), 21 aout 2025. Explique les echecs WAM en contexte RunAs et en tache sans session interactive. **Article Exchange Online PowerShell**, utilise pour comprendre la contrainte du contexte, pas comme correctif Office/RDS prouve. D'ou le controle de l'identite de session dans le kit.
4. [Microsoft Office Authentication/Identity Diagnostic (MSOAID)](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/Office/Client/activation/use-msoaid-tool-for-authentication-issues.md), 15 septembre 2026. Outil officiel de collecte lorsqu'un diagnostic simple ne suffit pas. Son utilisation et un eventuel envoi de traces sont manuels ; le kit ne capture ni n'envoie le trafic utilisateur.
5. [Signalement VS Code microsoft/vscode #240327](https://github.com/microsoft/vscode/issues/240327), ouvert le 11 fevrier 2025. Le tag `58tm1` apparait dans une trace MSAL avec le code decimal `2147942403` (`0x80070003`, chemin introuvable). Ce signalement concerne VS Code, pas Office/RDS ; il montre seulement l'importance du code et du contexte. Il ne suffit pas a decoder votre erreur ni a attribuer un taux de reussite a une solution.

Une recherche GitHub supplementaire sur WAM/FSLogix a notamment retourne une issue Azure CLI contenant `fslogix.com` dans une liste de domaines du tenant : **faux positif**, non retenu comme retour FSLogix. Les signaux non pertinents ne sont pas comptes comme preuves.

## References a verifier dans votre environnement

Ces references officielles sont fournies pour le suivi ; leur contenu courant **n'a pas pu etre consulte ici**, en raison de la restriction reseau sur Microsoft Learn. Ne pas les confondre avec les sources lues ci-dessus.

- [Parametres FSLogix, dont RoamIdentity](https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings)
- [Notes de version FSLogix](https://learn.microsoft.com/en-us/fslogix/overview-release-notes)
- [Problemes connus FSLogix](https://learn.microsoft.com/en-us/fslogix/troubleshooting-known-issues)
- [Activation d'ordinateur partage Microsoft 365 Apps](https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation)
- [Microsoft 365 Apps sur Windows Server](https://learn.microsoft.com/en-us/microsoft-365-apps/end-of-support/windows-server-support)
- [Problemes de connexion lors de l'activation Microsoft 365](https://learn.microsoft.com/en-us/troubleshoot/microsoft-365-apps/activation/sign-in-issues)

L'acces direct a Google, Microsoft Learn et Reddit a retourne un refus du proxy (`403`). Les domaines necessaires ont ete ajoutes au **brouillon** des parametres reseau ; cela ne les a pas rendus accessibles dans cette instance. Il est donc impossible de revendiquer ici une recherche exhaustive des forums ou un consensus d'administrateurs. Aucun pourcentage de reussite n'est invente.

## Pourquoi pas un « patch miracle »

- Pas de `DisableAADWAM=1`, `DisableADALatopWAMOverride=1` ni `EnableADAL=0` ajoutes automatiquement. Ces contournements modifient le parcours d'authentification et peuvent masquer une panne ; la reparation de base retire seulement ces valeurs locales lorsqu'elles bloquent l'authentification moderne. Les strategies sont signalees et doivent etre corrigees a leur source.
- Pas de `dsregcmd /leave`, de deconnexion automatique du compte professionnel, de suppression de `Microsoft\Crypto`, de `Protect`, du TPM/NGC, ni de recreation globale du profil. Ces actions affecteraient d'autres usages et ne sont pas justifiees par le tag seul.
- Pas de purge de tous les identifiants Windows, ni de reinitialisation de tous les packages AppX de tous les utilisateurs.
- Pas de `RoamIdentity=1` impose sur toute la ferme. Le comportement depend des versions, de la jointure et de la topologie ; des donnees d'authentification liees a un appareil ne doivent pas etre traitees comme un simple cache Office itinerant. Comparer la documentation de votre version et les hotes.
- Pas de KB fixe pour toutes les versions Windows Server, ni de mise a jour forcee Office/FSLogix. Relever les builds, verifier les notes officielles et tester un hote pilote avant maintenance.

## Priorite pratique

1. Collecter le message complet, l'heure et le correlation ID ; auditer un utilisateur touche et un cas sain.
2. Verifier si le compte fonctionne sur le web et consulter les journaux de connexion Entra en cas de refus serveur.
3. Dans la bonne session : verifier les strategies, remettre WAM en etat, puis retester.
4. Si le symptome correspond : reinitialiser uniquement l'identite Office, le dossier Accounts ou les licences utilisateur, un choix a la fois.
5. Si la panne revient au changement d'hote : verifier les versions identiques, la jointure, la configuration et les journaux FSLogix. Une purge repetee a chaque connexion serait un contournement, pas une resolution durable.
6. Generaliser seulement apres reussite du pilote et du test de persistance. Si echec, collecter avec MSOAID et ouvrir un dossier support avec les codes precis.
