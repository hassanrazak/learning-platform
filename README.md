# Learning Platform App 
App is using Java 17

## Setup DB

### Run Migration
`mvn clean install`

`mvn flyway:migrate flyway:info`

## Run Application
 `./mvnw spring-boot:run`


## SETTING UP AWS UNDER NEW ACCOUNT
 -- UPDATED PARAMETER STORE WITH RELEVANT
    ENV VARS
 -- ENABLED COGNITO
 -- THIS CHANGE ISSUED TO KICK OFF CI/CD PIPELINE 
    AND UPDATE INSTANCE ENV VARS
