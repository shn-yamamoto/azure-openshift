


```
                 azuredeploy.json
                       △
    ┌───────────┬──────┴─────┬───────────────┐
    │           │            │               │
master.json  node.json  infranode.json   jumpbox.json
    △           △            △               △
    │           └──────┬─────┘               │
master.sh            node.sh              jumpbox.sh

```
azuredeploy.json
  - Azure にサーバをデプロイする時のパラメータ

azuredeploy.parameters.json
  - パラメータのデフォルト値定義

master.json
  - master デプロイ時の設定

infranode.json
  - infranode デプロイ時の設定
