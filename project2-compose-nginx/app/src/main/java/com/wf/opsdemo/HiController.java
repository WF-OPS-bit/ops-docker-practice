package com.wf.opsdemo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 只提供 4 个接口，每个都对应 compose 编排里一个具体的验证项。
 */
@RestController
public class HiController {

    /** Docker 容器自带 HOSTNAME 环境变量（默认等于容器短 ID），用来区分命中的实例 */
    private final String instanceId;
    private final JdbcTemplate jdbcTemplate;
    private final StringRedisTemplate redisTemplate;

    public HiController(@Value("${HOSTNAME:${spring.application.name:unknown}}") String instanceId,
                        JdbcTemplate jdbcTemplate,
                        StringRedisTemplate redisTemplate) {
        this.instanceId = instanceId;
        this.jdbcTemplate = jdbcTemplate;
        this.redisTemplate = redisTemplate;
    }

    /** 负载均衡验证：Nginx 侧不缓存这个接口，所以每次都会打到后端 */
    @GetMapping("/api/hi")
    public Map<String, Object> hi() {
        return body("hit by " + instanceId);
    }

    /** proxy_cache 验证：内容里带时间戳，命中缓存后时间不再变化 */
    @GetMapping("/api/cache-time")
    public Map<String, Object> cacheTime() {
        return body("cached response from " + instanceId);
    }

    /** MySQL 连通性验证 */
    @GetMapping("/api/db")
    public Map<String, Object> db() {
        try {
            Map<String, Object> r = body("mysql ok");
            r.put("mysqlVersion", jdbcTemplate.queryForObject("SELECT VERSION()", String.class));
            r.put("mysqlNow", jdbcTemplate.queryForObject("SELECT NOW()", String.class));
            return r;
        } catch (Exception e) {
            Map<String, Object> r = body("mysql failed");
            r.put("error", String.valueOf(e.getMessage()));
            return r;
        }
    }

    /** Redis 连通性验证：计数器在两个实例间共享，可以顺带说明 Redis 做了共享状态 */
    @GetMapping("/api/redis")
    public Map<String, Object> redis() {
        try {
            Map<String, Object> r = body("redis ok");
            r.put("hits", redisTemplate.opsForValue().increment("ops-demo:hits"));
            return r;
        } catch (Exception e) {
            Map<String, Object> r = body("redis failed");
            r.put("error", String.valueOf(e.getMessage()));
            return r;
        }
    }

    private Map<String, Object> body(String msg) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("message", msg);
        m.put("instance", instanceId);
        m.put("time", LocalDateTime.now().toString());
        return m;
    }
}
