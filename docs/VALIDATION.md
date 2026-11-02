# Validation sur Windows / RDS

Le kit a ete construit sur Linux. Les operations Windows, AppX, les ACL NTFS, le Planificateur, FSLogix et la connexion Office doivent etre verifies sur un hote pilote. Le script n'est pas certifie pour une version de Windows Server sur laquelle il n'a pas ete execute.

## Pilote fonctionnel

1. Choisir un utilisateur affecte et un utilisateur sain. Sauvegarder le conteneur FSLogix selon la procedure d'exploitation, hors session active si le stockage l'exige.
2. Executer l'audit dans la session de l'utilisateur affecte. Conserver les builds Windows/Office/FSLogix, l'etat de jointure et le code complet Office.
3. Fermer Office. Lancer RepairUser avec `-WhatIf` : aucune cle, aucun cache, marqueur ou tache ne doit etre modifie. L'audit avec `-WhatIf` peut tout de meme effectuer les lectures et le test HTTPS demande, mais n'ecrit pas de rapport.
4. Appliquer la reparation de base et verifier le statut Broker. Une absence de package et un manifeste absent doivent arreter la reparation, pas declencher une purge.
5. Ouvrir Word, se connecter avec le MFA si demande, ouvrir un document. Verifier Outlook : ouverture du profil, envoi et reception d'un message de test autorise.
6. Fermer completement la session RDS (pas seulement deconnecter le client). Se reconnecter sur le meme hote, puis sur un autre hote du groupe. Refaire le test Office. Conserver chaque resultat separement.
7. Si besoin, tester UNE option de reinitialisation, en documentant le symptome et le resultat. Verifier que le dossier sauvegarde est present et que le manifeste est lisible avant tout nettoyage.

## Isolation et restauration

- Une application Office ouverte dans la session A doit empecher sa reparation, sans fermeture forcee. Une application uniquement dans la session B ne doit pas bloquer A et ne doit pas etre arretee.
- Une reparation lancee avec un compte admin different du compte de la session doit etre refusee. SYSTEM, WinRM/session 0 et un manifeste d'un autre utilisateur/hote doivent etre refuses.
- Tester Restore en simulation puis reellement sur le pilote. Verifier le contenu des cles restaurees, les caches sauvegardes et les caches regeneres conserves. Une erreur de hash doit arreter la restauration avant changement.
- Ne pas executer la reparation en parallele sur le meme profil. Si une interruption se produit entre une operation disque et son ecriture de journal, verifier manuellement l'etat avant de reprendre.

## Tache pour les utilisateurs

Installer apres le pilote avec une campagne unique. Dans une nouvelle session utilisateur standard : verifier le principal effectif, l'absence de privilege eleve, le resultat de la tache et le marqueur local. Tester aussi RemoteApp si utilise. Verifier qu'un deuxieme passage avec le meme identifiant et le meme hote ne repete pas le nettoyage ; un autre hote doit avoir son propre marqueur.

Une operation locale terminee ne prouve pas que l'utilisateur a pu se reconnecter a Office. La tache ne tente pas de soumettre des identifiants ni d'automatiser le MFA. Retirer la tache une fois la campagne terminee si elle n'est plus necessaire.

## Maintenance FSLogix / Office / Windows

Comparer les versions de tous les hotes avec les notes de version et les cycles de support officiels. Lire les parametres de la version installee, les exclusions/redirections et les journaux de montage de conteneur. Verifier la persistance sur un conteneur sain, les droits de stockage, le mode de jointure de chaque hote et l'activation partagee si applicable. Le kit ne modifie pas ces reglages automatiquement et n'atteste pas une licence eligibile.
