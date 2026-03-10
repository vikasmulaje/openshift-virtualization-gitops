#!/usr/bin/env groovy
@Library('kni-qe-ci-lib') _

pipeline {
    agent { label "${params.HOST}" }
    
    options {
        buildDiscarder(logRotator(
            daysToKeepStr: '30',
            numToKeepStr: '200',
            artifactDaysToKeepStr: '30',
            artifactNumToKeepStr: '60'
        ))
        timestamps()
        ansiColor('xterm')
        lock (label: "${checkLock(params.HOST)}", quantity: 1)
    }

    parameters {
        separator(name: "Host and Network Details", sectionHeader: "Host and Network Details")
        
        string(name: 'HOST', 
               trim: true,
               defaultValue: 'HOST', 
               description: 'REQUIRED: Hypervisor/Agent to run on')
               
        string(name: 'LIBVIRT_NETWORK', 
               defaultValue: 'ocp3m0w-ic4s20', 
               description: 'The libvirt network name from Hub')
        
        separator(name: "Repository Configuration", sectionHeader: "Repository Configuration")

        string(name: 'GITOPS_REPO', 
               defaultValue: 'https://gitlab.cee.redhat.com/certification-qe/openshift-virtualization-gitops.git', 
               description: 'The GitOps repository URL')

        string(name: 'GITOPS_BRANCH', 
               defaultValue: 'main', 
               description: 'Can change to feature for testing')

        separator(name: "Deployment Configuration", sectionHeader: "Deployment Configuration")
        
        choice(name: 'CLUSTERS', 
               choices: ['etl4', 'both'], 
               description: 'Which spoke clusters to deploy (etl4 only, or etl4 and etl6)')
               
        booleanParam(name: 'CLEANUP', 
                     defaultValue: false, 
                     description: 'If true, destroys existing VMs for the targeted spokes before creating new ones')

        booleanParam(name: 'TEST', 
                     defaultValue: true, 
                     description: 'If true, runs post-deployment validation tests on the deployed clusters')
        
        separator(name: "Notifications", sectionHeader: "Notifications")
        
        string(name: 'SLACK_CHANNEL', 
               defaultValue: 'eco-ci-reporting', 
               description: 'Slack channel to post build results to')
    }

    stages {
        stage('Checkout GitOps Repo') {
            steps {
                retry(3) {
                    checkout changelog: false,
                        poll: false,
                        scm: [
                            $class: 'GitSCM',
                            branches: [[name: "${params.GITOPS_BRANCH}"]],
                            doGenerateSubmoduleConfigurations: false,
                            extensions: [
                                [$class: 'CloneOption', noTags: true, reference: '', shallow: true],
                                [$class: 'PruneStaleBranch'],
                                [$class: 'CleanCheckout'],
                                [$class: 'IgnoreNotifyCommit'],
                                [$class: 'RelativeTargetDirectory', relativeTargetDir: 'openshift-virtualization-gitops']
                            ],
                            submoduleCfg: [],
                            userRemoteConfigs: [[
                                name: 'origin',
                                refspec: "+refs/heads/${params.GITOPS_BRANCH}:refs/remotes/origin/${params.GITOPS_BRANCH}",
                                url: "${params.GITOPS_REPO}"
                            ]]
                        ]
                } // end retry
            }
        }

        stage('Execute GitOps Spoke Deployment') {
            steps {
                script {
                    def cleanupFlag = params.CLEANUP ? '--cleanup' : ''
                    def testFlag = params.TEST ? '--test' : ''
                    
                    sh """
                    #!/bin/bash
                    set -e
                    
                    echo "======================================================="
                    echo "Starting GitOps Spoke Deployment on ${params.HOST}"
                    echo "Target Clusters: ${params.CLUSTERS}"
                    echo "Libvirt Network: ${params.LIBVIRT_NETWORK}"
                    echo "Running Tests: ${params.TEST}"
                    echo "======================================================="
                    
                    # Navigate into the checked out directory
                    cd openshift-virtualization-gitops
                    
                    # Ensure the script is executable
                    chmod +x gitops_pipeline_e2e.sh
                    
                    ./gitops_pipeline_e2e.sh \\
                        --local \\
                        --host ${params.HOST} \\
                        --network ${params.LIBVIRT_NETWORK} \\
                        --clusters ${params.CLUSTERS} \\
                        ${cleanupFlag} \\
                        ${testFlag}
                    """
                }
            }
        }
    }

post {
        always {
            script {
                sh 'cp /tmp/deployment-reports/gitops-e2e-test.html ./gitops-e2e-test.html || echo "WARNING: Test report not found in /tmp/deployment-reports/"'
                archiveArtifacts artifacts: 'gitops-e2e-test.html', allowEmptyArchive: true

                // Publishes HTML Test File
                publishHTML(target: [
                    allowMissing: true,
                    alwaysLinkToLastBuild: true,
                    keepAll: true,
                    reportDir: '.',
                    reportFiles: 'gitops-e2e-test.html',
                    reportName: 'Deployment Test Report'
                ])

                // Set Slack message params
                def buildStatus = currentBuild.currentResult ?: 'SUCCESS'
                def isSuccess = (buildStatus == 'SUCCESS')
                def buildColor = isSuccess ? 'good' : 'danger' 
                def statusEmoji = isSuccess ? '🟢' : '🔴'
                
                def htmlReportUrl = "${env.BUILD_URL}Deployment%20Test%20Report/"
                
                // Construct Slack Message
                def slackMsg = "${statusEmoji} *GitOps Spoke Deployment on Agent: ${params.HOST}*\n" +
                               "Target: ${params.CLUSTERS}\n" +
                               "Tests Executed: ${params.TEST}\n" +
                               "Status: *${buildStatus}*\n" +
                               "Build URL: ${env.BUILD_URL}\n" +
                               "<${htmlReportUrl}|HTML Test Report Build here>"
                
                // Send Slack message
                slackSend(
                    channel: params.SLACK_CHANNEL,
                    color: buildColor,
                    message: slackMsg,
                    teamDomain: 'redhat-internal',
                    tokenCredentialId: 'assisted-slack-bot-token-new'
                )
            }
        }
        cleanup {
            cleanWs()
        }
    }
}