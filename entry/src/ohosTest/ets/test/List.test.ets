import portSmokeTest from './PortSmoke.test';
import serviceConfigTest from './ServiceConfig.test';
import taskConfigTest from './TaskConfig.test';
import executionTest from './Execution.test';
import metricReportTest from './MetricReport.test';
import runRecordTest from './RunRecord.test';
import appSettingsTest from './AppSettings.test';
import integrationTest from './Integration.test';

export default function testsuite() {
  portSmokeTest();
  serviceConfigTest();
  taskConfigTest();
  executionTest();
  metricReportTest();
  runRecordTest();
  appSettingsTest();
  integrationTest();
}