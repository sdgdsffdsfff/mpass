## mpass
适用于公司内部小型团队使用的精简版PAAS平台；

## 术语定义：

* app:        应用，分为WEB应用和Worker应用
* instance:   实例，每个应用由多个实例构成
* container:  容器，每个实例运行在一个docker容器中
* node:       节点服务器，分为

   ** container node:  运行container
   ** router node:     运行router

## 组件：
* scheduler:  中控模块
* hades:      运行在每个container node上的agent，负责接收来自scheduler的命令并执行
* docker:     运行在每个container node上，负责管理container
* router:     运行在每个router node上的agent
* nginx:      运行在每个router node上，负责负载均衡

## 一期功能：
* 自动部署
* 负载均衡
* 支持SVN/GIT等方式获取代码
* 实例水平扩展（手动）
* WEB和Worker类型的应用

## 二期功能：
* instance健康检查，故障自动迁移
* 资源垂直调整
* RESTful API

## 三期功能：
* 负载自动探测，instance自动伸缩

