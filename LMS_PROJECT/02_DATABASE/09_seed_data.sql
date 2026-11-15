-- =============================================================================
-- Seed data + scheduler jobs | Oracle 19c | STATUS: written, NOT executed
-- Idempotent (MERGE / existence checks). Requires 01-08.
-- =============================================================================

-- ---------- Roles ------------------------------------------------------------------
MERGE INTO lms_roles t
USING (SELECT 'LEARNER' c, 'Learner' en, 'متعلم' ar FROM dual UNION ALL
       SELECT 'INSTRUCTOR', 'Instructor', 'مدرب' FROM dual UNION ALL
       SELECT 'MANAGER', 'Department Manager', 'مدير الإدارة' FROM dual UNION ALL
       SELECT 'TRAINING_ADMIN', 'Training Administrator', 'مسؤول التدريب' FROM dual UNION ALL
       SELECT 'HR_LD', 'HR / Learning Development Officer', 'موارد بشرية / تطوير التعلم' FROM dual UNION ALL
       SELECT 'SYS_ADMIN', 'System Administrator', 'مسؤول النظام' FROM dual) s
   ON (t.role_code = s.c)
 WHEN NOT MATCHED THEN INSERT (role_code, name_en, name_ar) VALUES (s.c, s.en, s.ar);

-- ---------- Permissions -------------------------------------------------------------
MERGE INTO lms_permissions t
USING (SELECT column_value c FROM TABLE(sys.odcivarchar2list(
         'CATALOG_VIEW','ENROLL_SELF','ENROLL_ASSIGN','ENROLL_APPROVE','COURSE_AUTHOR','COURSE_PUBLISH',
         'QUIZ_TAKE','QUIZ_AUTHOR','GRADE','SESSION_MANAGE','CERT_VIEW_OWN','CERT_POLICY','CERT_REVOKE',
         'SKILL_MANAGE','REPORT_TEAM','REPORT_ORG','USER_ADMIN','ROLE_ADMIN','SETTINGS_ADMIN','AUDIT_VIEW',
         'RATELIMIT_ADMIN','NOTIF_TEMPLATE_ADMIN'))) s
   ON (t.permission_code = s.c)
 WHEN NOT MATCHED THEN INSERT (permission_code, description) VALUES (s.c, 'LMS permission ' || s.c);

-- ---------- Role -> permission matrix (doc 01 section 2.4) ----------------------------
MERGE INTO lms_role_permissions t
USING (
  SELECT r.role_id, p.permission_id, m.scope
    FROM (
      SELECT 'LEARNER' r, 'CATALOG_VIEW' p, 'ALL' scope FROM dual UNION ALL
      SELECT 'INSTRUCTOR','CATALOG_VIEW','ALL' FROM dual UNION ALL
      SELECT 'MANAGER','CATALOG_VIEW','ALL' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','CATALOG_VIEW','ALL' FROM dual UNION ALL
      SELECT 'HR_LD','CATALOG_VIEW','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','CATALOG_VIEW','ALL' FROM dual UNION ALL
      SELECT 'LEARNER','ENROLL_SELF','OWN' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','ENROLL_SELF','OWN' FROM dual UNION ALL
      SELECT 'MANAGER','ENROLL_SELF','OWN' FROM dual UNION ALL
      SELECT 'HR_LD','ENROLL_SELF','OWN' FROM dual UNION ALL
      SELECT 'MANAGER','ENROLL_ASSIGN','TEAM' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','ENROLL_ASSIGN','ALL' FROM dual UNION ALL
      SELECT 'HR_LD','ENROLL_ASSIGN','ALL' FROM dual UNION ALL
      SELECT 'MANAGER','ENROLL_APPROVE','TEAM' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','ENROLL_APPROVE','ALL' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','COURSE_AUTHOR','ASSIGNED' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','COURSE_AUTHOR','ALL' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','COURSE_PUBLISH','ALL' FROM dual UNION ALL
      SELECT 'LEARNER','QUIZ_TAKE','OWN' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','QUIZ_TAKE','OWN' FROM dual UNION ALL
      SELECT 'MANAGER','QUIZ_TAKE','OWN' FROM dual UNION ALL
      SELECT 'HR_LD','QUIZ_TAKE','OWN' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','QUIZ_AUTHOR','ASSIGNED' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','QUIZ_AUTHOR','ALL' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','GRADE','ASSIGNED' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','GRADE','ALL' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','SESSION_MANAGE','ASSIGNED' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','SESSION_MANAGE','ALL' FROM dual UNION ALL
      SELECT 'LEARNER','CERT_VIEW_OWN','OWN' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','CERT_VIEW_OWN','OWN' FROM dual UNION ALL
      SELECT 'MANAGER','CERT_VIEW_OWN','OWN' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','CERT_VIEW_OWN','OWN' FROM dual UNION ALL
      SELECT 'HR_LD','CERT_VIEW_OWN','OWN' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','CERT_POLICY','ALL' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','CERT_REVOKE','ALL' FROM dual UNION ALL
      SELECT 'HR_LD','SKILL_MANAGE','ALL' FROM dual UNION ALL
      SELECT 'INSTRUCTOR','REPORT_TEAM','ASSIGNED' FROM dual UNION ALL
      SELECT 'MANAGER','REPORT_TEAM','TEAM' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','REPORT_TEAM','ALL' FROM dual UNION ALL
      SELECT 'HR_LD','REPORT_TEAM','ALL' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','REPORT_ORG','ALL' FROM dual UNION ALL
      SELECT 'HR_LD','REPORT_ORG','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','USER_ADMIN','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','ROLE_ADMIN','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','SETTINGS_ADMIN','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','AUDIT_VIEW','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','RATELIMIT_ADMIN','ALL' FROM dual UNION ALL
      SELECT 'SYS_ADMIN','NOTIF_TEMPLATE_ADMIN','ALL' FROM dual UNION ALL
      SELECT 'TRAINING_ADMIN','NOTIF_TEMPLATE_ADMIN','ASSIGNED' FROM dual) m
    JOIN lms_roles r ON r.role_code = m.r
    JOIN lms_permissions p ON p.permission_code = m.p) s
   ON (t.role_id = s.role_id AND t.permission_id = s.permission_id)
 WHEN MATCHED THEN UPDATE SET t.scope = s.scope
 WHEN NOT MATCHED THEN INSERT (role_id, permission_id, scope) VALUES (s.role_id, s.permission_id, s.scope);

-- ---------- Categories (configurable; these are only starter rows) --------------------------
MERGE INTO lms_categories t
USING (SELECT 'Leadership' en, 'القيادة' ar, 10 so FROM dual UNION ALL
       SELECT 'Management', 'الإدارة', 20 FROM dual UNION ALL
       SELECT 'Information Technology', 'تقنية المعلومات', 30 FROM dual UNION ALL
       SELECT 'Cybersecurity', 'الأمن السيبراني', 40 FROM dual UNION ALL
       SELECT 'Digital Transformation', 'التحول الرقمي', 50 FROM dual UNION ALL
       SELECT 'Finance', 'المالية', 60 FROM dual UNION ALL
       SELECT 'Human Resources', 'الموارد البشرية', 70 FROM dual UNION ALL
       SELECT 'Safety and Compliance', 'السلامة والالتزام', 80 FROM dual UNION ALL
       SELECT 'Technical Skills', 'المهارات الفنية', 90 FROM dual UNION ALL
       SELECT 'Professional Development', 'التطوير المهني', 100 FROM dual) s
   ON (t.name_en = s.en AND t.parent_category_id IS NULL)
 WHEN NOT MATCHED THEN INSERT (name_en, name_ar, sort_order) VALUES (s.en, s.ar, s.so);

-- ---------- Settings ------------------------------------------------------------------------
MERGE INTO lms_system_settings t
USING (SELECT 'RETAIN_AUDIT_DAYS' k, '2555' v, 'Audit log retention (days)' d FROM dual UNION ALL
       SELECT 'RETAIN_SECEVENT_DAYS', '730', 'Security events retention (days)' FROM dual UNION ALL
       SELECT 'RETAIN_APILOG_DAYS', '90', 'API request log retention (days)' FROM dual UNION ALL
       SELECT 'RETAIN_ACTIVITY_DAYS', '730', 'Learning activity event retention (days)' FROM dual UNION ALL
       SELECT 'RETAIN_NOTIF_DAYS', '180', 'Read in-app notification retention (days)' FROM dual UNION ALL
       SELECT 'QUIZ_GRACE_SECONDS', '10', 'Grace after quiz deadline before auto-submit' FROM dual UNION ALL
       SELECT 'PROGRESS_MAX_DELTA_SEC', '120', 'Max seconds credited per progress event' FROM dual UNION ALL
       SELECT 'APPROVAL_ESCALATE_DAYS', '3', 'Days before an approval is escalated' FROM dual UNION ALL
       SELECT 'RENEWAL_WINDOW_DAYS', '90', 'Days before expiry that renewal training is assigned' FROM dual UNION ALL
       SELECT 'CERT_VERIFY_NAME', 'INITIALS', 'Holder shown on public verification: FULL | INITIALS | NONE' FROM dual UNION ALL
       SELECT 'REVIEW_REQUIRES_COMPLETION', 'Y', 'Y = reviews only after completion' FROM dual UNION ALL
       SELECT 'DEFAULT_CERT_TEMPLATE', 'DEFAULT', 'Template code used when a course has none' FROM dual UNION ALL
       SELECT 'MAIL_FROM', 'lms-noreply@example.invalid', 'Sender address (set per environment)' FROM dual UNION ALL
       SELECT 'APEX_WORKSPACE', 'LMS', 'APEX workspace name used by APEX_MAIL from jobs (set per environment)' FROM dual UNION ALL
       SELECT 'FEEDBACK_MIN_RESPONSES', '5', 'Minimum responses before course feedback is shown to instructors (anonymity)' FROM dual UNION ALL
       SELECT 'REVIEW_EDIT_DAYS', '0', 'Days a learner may edit a review (0 = reviews are final)' FROM dual) s
   ON (t.setting_key = s.k)
 WHEN NOT MATCHED THEN INSERT (setting_key, setting_value, description) VALUES (s.k, s.v, s.d);

-- ---------- Rate-limit policy for public verification ----------------------------------------
MERGE INTO lms_rate_limit_policies t
USING (SELECT 'CERT_VERIFY' op FROM dual) s ON (t.operation_name = s.op)
 WHEN NOT MATCHED THEN INSERT (operation_name, limit_count, window_seconds, fail_mode)
      VALUES ('CERT_VERIFY', 30, 60, 'OPEN');

-- ---------- Certificate templates and default feedback form ------------------------------------
MERGE INTO lms_certificate_templates t
USING (SELECT 'DEFAULT' c, 'Certificate of Completion' en, 'شهادة إتمام' ar, CAST(NULL AS NUMBER) vm FROM dual UNION ALL
       SELECT 'COMPLIANCE_1Y', 'Compliance Certificate (1 year)', 'شهادة التزام (سنة)', 12 FROM dual) s
   ON (t.template_code = s.c)
 WHEN NOT MATCHED THEN INSERT (template_code, name_en, name_ar, validity_months, body_html)
      VALUES (s.c, s.en, s.ar, s.vm,
              '<h1>{{title}}</h1><p>{{holder}}</p><p>{{issued}}</p><p>{{number}}</p>');

DECLARE
  l_form NUMBER;
BEGIN
  BEGIN
    SELECT form_id INTO l_form FROM lms_feedback_forms WHERE name_en = 'Post-course evaluation';
  EXCEPTION WHEN NO_DATA_FOUND THEN
    INSERT INTO lms_feedback_forms (name_en, name_ar) VALUES ('Post-course evaluation', 'تقييم ما بعد الدورة')
    RETURNING form_id INTO l_form;
    INSERT INTO lms_feedback_questions (form_id, text_en, text_ar, answer_type, sort_order) VALUES
      (l_form, 'The course objectives were clear.', 'كانت أهداف الدورة واضحة.', 'RATING', 1);
    INSERT INTO lms_feedback_questions (form_id, text_en, text_ar, answer_type, sort_order) VALUES
      (l_form, 'The content is relevant to my work.', 'المحتوى مرتبط بعملي.', 'RATING', 2);
    INSERT INTO lms_feedback_questions (form_id, text_en, text_ar, answer_type, sort_order) VALUES
      (l_form, 'What could be improved?', 'ما الذي يمكن تحسينه؟', 'TEXT', 3);
  END;
END;
/

-- ---------- Notification templates (en / ar). Placeholders: {{key}} ---------------------------
DECLARE
  PROCEDURE t(p_code VARCHAR2, p_s_en VARCHAR2, p_b_en VARCHAR2, p_s_ar VARCHAR2, p_b_ar VARCHAR2) IS
  BEGIN
    MERGE INTO lms_notification_templates x USING (SELECT p_code c, 'en' l FROM dual) s
       ON (x.template_code = s.c AND x.lang = s.l)
     WHEN NOT MATCHED THEN INSERT (template_code, lang, subject, body) VALUES (p_code, 'en', p_s_en, p_b_en);
    MERGE INTO lms_notification_templates x USING (SELECT p_code c, 'ar' l FROM dual) s
       ON (x.template_code = s.c AND x.lang = s.l)
     WHEN NOT MATCHED THEN INSERT (template_code, lang, subject, body) VALUES (p_code, 'ar', p_s_ar, p_b_ar);
  END t;
BEGIN
  t('ENROLL_CONFIRM', 'Enrolment confirmed: {{course}}', 'You are enrolled in "{{course}}". You can start learning now.',
    'تم تأكيد التسجيل: {{course}}', 'تم تسجيلك في دورة "{{course}}". يمكنك البدء بالتعلم الآن.');
  t('ENROLL_PENDING', 'Enrolment awaiting approval: {{course}}', 'Your request for "{{course}}" was sent for approval.',
    'طلب التسجيل بانتظار الموافقة: {{course}}', 'تم إرسال طلبك للتسجيل في دورة "{{course}}" للموافقة.');
  t('ENROLL_WAITLIST', 'You are on the waiting list: {{course}}', '"{{course}}" is full. You were added to the waiting list and will be notified when a seat is free.',
    'أنت في قائمة الانتظار: {{course}}', 'دورة "{{course}}" مكتملة العدد. تمت إضافتك إلى قائمة الانتظار وسيتم إشعارك عند توفر مقعد.');
  t('ENROLL_PROMOTED', 'A seat is available: {{course}}', 'A seat became available and you are now enrolled in "{{course}}".',
    'تم توفر مقعد: {{course}}', 'توفر مقعد وتم تسجيلك الآن في دورة "{{course}}".');
  t('ENROLL_APPROVED', 'Enrolment approved: {{course}}', 'Your enrolment in "{{course}}" was approved.',
    'تمت الموافقة على التسجيل: {{course}}', 'تمت الموافقة على تسجيلك في دورة "{{course}}".');
  t('ENROLL_REJECTED', 'Enrolment not approved: {{course}}', 'Your enrolment request for "{{course}}" was not approved.',
    'لم تتم الموافقة على التسجيل: {{course}}', 'لم تتم الموافقة على طلب تسجيلك في دورة "{{course}}".');
  t('MANDATORY_ASSIGNED', 'Mandatory training assigned: {{course}}', 'You have been assigned "{{course}}". Due date: {{due}}.',
    'تدريب إلزامي: {{course}}', 'تم تكليفك بدورة "{{course}}". تاريخ الاستحقاق: {{due}}.');
  t('MANDATORY_REMINDER', 'Reminder: {{course}} due {{due}}', 'Please complete "{{course}}". Due date: {{due}}.',
    'تذكير: {{course}} - الاستحقاق {{due}}', 'يرجى إكمال دورة "{{course}}". تاريخ الاستحقاق: {{due}}.');
  t('MANDATORY_OVERDUE', 'Overdue training: {{employee}}', '{{employee}} has not completed "{{course}}" ({{days}} day(s) overdue).',
    'تدريب متأخر: {{employee}}', 'لم يكمل {{employee}} دورة "{{course}}" (متأخر {{days}} يوم).');
  t('APPROVAL_REQUEST', 'Approval needed: {{item}}', '{{requester}} requested approval for "{{item}}".',
    'مطلوب موافقتك: {{item}}', 'طلب {{requester}} الموافقة على "{{item}}".');
  t('APPROVAL_ESCALATED', 'Escalated approval: {{item}}', 'An overdue approval was escalated to you: {{item}}.',
    'موافقة مصعّدة: {{item}}', 'تم تصعيد طلب موافقة متأخر إليك: {{item}}.');
  t('COURSE_APPROVED', 'Course published: {{course}}', 'Your course "{{course}}" was approved and published.',
    'تم نشر الدورة: {{course}}', 'تمت الموافقة على دورتك "{{course}}" ونشرها.');
  t('COURSE_REJECTED', 'Course returned: {{course}}', 'Your course "{{course}}" was returned to draft. Reviewer note: {{note}}',
    'أعيدت الدورة: {{course}}', 'أعيدت دورتك "{{course}}" إلى المسودة. ملاحظة المراجع: {{note}}');
  t('COURSE_COMPLETE', 'Course completed: {{course}}', 'Congratulations, you completed "{{course}}".',
    'تم إكمال الدورة: {{course}}', 'تهانينا، لقد أكملت دورة "{{course}}".');
  t('ASSESSMENT_RESULT', 'Assessment result: {{quiz}}', 'Your score for "{{quiz}}" is {{score}}% ({{result}}).',
    'نتيجة الاختبار: {{quiz}}', 'نتيجتك في "{{quiz}}" هي {{score}}% ({{result}}).');
  t('PATH_COMPLETE', 'Learning path completed: {{path}}', 'You completed the learning path "{{path}}".',
    'اكتمل المسار التعليمي: {{path}}', 'لقد أكملت المسار التعليمي "{{path}}".');
  t('SESSION_REGISTERED', 'Session registration: {{start}}', 'Your registration status ({{status}}) for the session starting {{start}}.',
    'التسجيل في الجلسة: {{start}}', 'حالة تسجيلك ({{status}}) في الجلسة التي تبدأ {{start}}.');
  t('SESSION_CANCELLED', 'Session cancelled: {{course}}', 'The session of "{{course}}" on {{start}} was cancelled.',
    'تم إلغاء الجلسة: {{course}}', 'تم إلغاء جلسة "{{course}}" المقررة في {{start}}.');
  t('SESSION_RESCHEDULED', 'Session rescheduled: {{course}}', 'The session of "{{course}}" moved to {{start}}.',
    'تمت إعادة جدولة الجلسة: {{course}}', 'تم نقل جلسة "{{course}}" إلى {{start}}.');
  t('CERT_ISSUED', 'Certificate issued: {{title}}', 'Your certificate {{number}} for "{{title}}" is ready. Expires: {{expires}}.',
    'تم إصدار الشهادة: {{title}}', 'شهادتك رقم {{number}} لـ "{{title}}" جاهزة. تاريخ الانتهاء: {{expires}}.');
  t('CERT_EXPIRING', 'Certificate expiring: {{title}}', 'Your certificate "{{title}}" expires on {{expires}} ({{days}} days).',
    'شهادة قاربت على الانتهاء: {{title}}', 'تنتهي شهادتك "{{title}}" بتاريخ {{expires}} (بعد {{days}} يوم).');
  t('CERT_EXPIRED', 'Certificate expired: {{title}}', 'Your certificate "{{title}}" has expired.',
    'انتهت صلاحية الشهادة: {{title}}', 'انتهت صلاحية شهادتك "{{title}}".');
  t('CERT_REVOKED', 'Certificate revoked: {{title}}', 'Your certificate "{{title}}" was revoked.',
    'تم إلغاء الشهادة: {{title}}', 'تم إلغاء شهادتك "{{title}}".');
END;
/

-- ---------- Scheduler jobs (idempotent) ----------------------------------------------------------
DECLARE
  PROCEDURE j(p_name VARCHAR2, p_action VARCHAR2, p_interval VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_scheduler_jobs WHERE job_name = p_name;
    IF l_n = 0 THEN
      DBMS_SCHEDULER.create_job(job_name => p_name, job_type => 'PLSQL_BLOCK', job_action => p_action,
                                repeat_interval => p_interval, enabled => TRUE);
    END IF;
  END j;
BEGIN
  j('LMS_NOTIF_JOB',        'BEGIN lms_notification_pkg.process_queue; END;', 'FREQ=MINUTELY;INTERVAL=1');
  j('LMS_SUMMARY_JOB',      'BEGIN lms_reporting_pkg.refresh_summaries; END;', 'FREQ=HOURLY;INTERVAL=1');
  j('LMS_CERT_JOB',         'BEGIN lms_certification_pkg.expire_due; lms_certification_pkg.renewal_sweep; END;', 'FREQ=DAILY;BYHOUR=1;BYMINUTE=10');
  j('LMS_ASSIGN_SYNC_JOB',  'BEGIN lms_enrollment_pkg.sync_assignments; END;', 'FREQ=DAILY;BYHOUR=1;BYMINUTE=40');
  j('LMS_PURGE_JOB',        'BEGIN lms_reporting_pkg.purge_logs; END;', 'FREQ=DAILY;BYHOUR=2;BYMINUTE=20');
  j('LMS_REMINDER_JOB',     'BEGIN lms_reporting_pkg.send_reminders; END;', 'FREQ=DAILY;BYHOUR=6;BYMINUTE=15');
  j('LMS_APPROVAL_ESC_JOB', 'BEGIN lms_approval_pkg.escalate_overdue; END;', 'FREQ=DAILY;BYHOUR=7;BYMINUTE=5');
END;
/
COMMIT;
